# API de Pagamentos PIX — Integração Externa

Documentação para integração com o módulo de pagamentos do servidor **wssh-vpn**.

---

## Índice

- [Visão Geral](#visão-geral)
- [Configuração do Servidor](#configuração-do-servidor)
- [Autenticação](#autenticação)
- [Endpoints](#endpoints)
  - [Criar Cobrança](#post-apipagamentosexternosiniciar)
  - [Confirmar ou Cancelar](#post-apipagamentosexternos)
  - [Consultar Status](#get-apipagamentostatusid)
- [Notificação Automática](#notificação-automática-fluxo-principal)
- [Idempotência](#idempotência)
- [Erros](#respostas-de-erro)
- [Exemplo Completo](#exemplo-completo--fluxo-de-ponta-a-ponta)

---

## Visão Geral

O servidor funciona exclusivamente como **processador de pagamento**. Ele não cria usuários VPN para pagamentos externos — apenas gera a cobrança e notifica sua aplicação quando o pagamento é confirmado.

```
Sua App → POST /iniciar → QR Code gerado
Cliente paga via app bancária
Gateway confirma → servidor notifica sua URL automaticamente
```

**Fluxo resumido:**

1. Sua app chama `/api/pagamentos/externos/iniciar` e recebe o QR Code
2. O cliente escaneia e paga
3. O gateway notifica o servidor
4. O servidor envia `POST` automático para sua `pix_external_notify_url`
5. Sua app processa e libera o acesso para o cliente

---

## Configuração do Servidor

Dois arquivos controlam o comportamento da integração. **Não é necessário reiniciar o servidor** — as configurações são relidas a cada 60 segundos.

### `./data/.env`

Define o segredo HMAC usado para assinar e verificar todas as requisições.

```bash
# ./data/.env
pix_webhook_secret=seu_segredo_muito_seguro_aqui
```

### `./data/external_notify_url.json`

Lista de URLs que receberão o `POST` automático após cada pagamento confirmado. Suporta múltiplas URLs — todas são notificadas.

```json
{
  "urls": [
    "https://minha-app.com/webhook/pagamento",
    "https://outra-app.com/notificacoes/pix"
  ]
}
```

> **Dica:** Você pode adicionar ou remover URLs sem reiniciar o servidor. As mudanças entram em vigor em até 60 segundos.

---

## Autenticação

Quando `pix_webhook_secret` estiver configurado, **todas as requisições devem incluir o header `X-Signature`** com o HMAC-SHA256 do corpo em hexadecimal. Requisições sem assinatura ou com assinatura inválida são rejeitadas com `401`.

### Gerando a assinatura

```bash
BODY='{"cliente_nome":"João","cliente_email":"joao@email.com","plano_tipo":"mensal","valor":49.90}'
SECRET="seu_segredo_aqui"

SIG=$(echo -n "$BODY" | openssl dgst -sha256 -hmac "$SECRET" -hex | awk '{print $2}')
echo $SIG
# → a3f9c2e1d4b7...
```

A mesma lógica se aplica tanto para **requisições enviadas à API** quanto para **validar as notificações recebidas** da sua URL.

---

## Endpoints

### `POST /api/pagamentos/externos/iniciar`

Cria uma cobrança PIX. O valor e o rótulo do plano são definidos por você — não há vínculo com planos internos do servidor.

**Headers obrigatórios:**

| Header | Descrição |
|---|---|
| `Content-Type` | `application/json` |
| `X-Signature` | HMAC-SHA256 do corpo (quando secret configurado) |
| `X-Idempotency-Key` | *(Recomendado)* UUID único por cobrança — evita duplicatas |

**Campos do corpo:**

| Campo | Tipo | Obrigatório | Descrição |
|---|---|---|---|
| `cliente_nome` | string | ✅ | Nome do cliente |
| `cliente_email` | string | ✅ | E-mail do cliente |
| `cliente_tel` | string | — | Telefone (ex: `11999998888`) |
| `plano_tipo` | string | ✅ | Rótulo livre (ex: `"mensal"`, `"gold"`) |
| `valor` | float | ✅ | Valor em reais — mín. `0.50`, máx. `10000.00` |
| `plano_dias` | int | — | Informativo — aparece na notificação |

**Requisição:**

```bash
BODY=$(cat <<'EOF'
{
  "cliente_nome":  "João da Silva",
  "cliente_email": "joao@email.com",
  "cliente_tel":   "11999998888",
  "plano_tipo":    "mensal",
  "valor":         49.90,
  "plano_dias":    30
}
EOF
)

SECRET="seu_segredo_aqui"
SIG=$(echo -n "$BODY" | openssl dgst -sha256 -hmac "$SECRET" -hex | awk '{print $2}')

curl -s -X POST https://seuservidor.com/api/pagamentos/externos/iniciar \
  -H "Content-Type: application/json" \
  -H "X-Signature: $SIG" \
  -H "X-Idempotency-Key: pedido-$(uuidgen)" \
  -d "$BODY"
```

**Resposta `200 OK`:**

```json
{
  "success":       true,
  "id":            "a1b2c3d4-e5f6-7890-abcd-ef1234567890",
  "txid":          "abc123def456ghi789",
  "qrcode_base64": "iVBORw0KGgoAAAANSUhEUgAA...",
  "payload_emv":   "00020101021226580014br.gov.bcb.pix...",
  "valor":         49.90,
  "plano_tipo":    "mensal",
  "expira_em":     "2025-03-15T15:30:00Z"
}
```

> ⚠️ **Guarde o campo `id`** — você precisará dele para consultas, reconciliação e confirmação manual.

---

### `POST /api/pagamentos/externos`

Confirma ou cancela um pagamento já criado. Use quando sua app receber confirmação por um canal alternativo ao gateway (ex: checkout próprio).

**Campos do corpo:**

| Campo | Obrigatório | Descrição |
|---|---|---|
| `pagamento_id` | ✅ (ou `txid`) | ID retornado no momento da criação |
| `txid` | ✅ (ou `pagamento_id`) | TxID do PIX — alternativa ao `pagamento_id` |
| `status` | ✅ | `"pago"` ou `"cancelado"` |
| `observacoes` | — | Texto livre para log interno |

**Confirmar por `pagamento_id`:**

```bash
BODY=$(cat <<'EOF'
{
  "pagamento_id": "a1b2c3d4-e5f6-7890-abcd-ef1234567890",
  "status":       "pago",
  "observacoes":  "Confirmado via checkout próprio"
}
EOF
)

SIG=$(echo -n "$BODY" | openssl dgst -sha256 -hmac "seu_segredo_aqui" -hex | awk '{print $2}')

curl -s -X POST https://seuservidor.com/api/pagamentos/externos \
  -H "Content-Type: application/json" \
  -H "X-Signature: $SIG" \
  -d "$BODY"
```

**Confirmar por `txid`:**

```bash
BODY='{"txid":"abc123def456ghi789","status":"pago"}'

SIG=$(echo -n "$BODY" | openssl dgst -sha256 -hmac "seu_segredo_aqui" -hex | awk '{print $2}')

curl -s -X POST https://seuservidor.com/api/pagamentos/externos \
  -H "Content-Type: application/json" \
  -H "X-Signature: $SIG" \
  -d "$BODY"
```

**Cancelar:**

```bash
BODY='{"pagamento_id":"a1b2c3d4-e5f6-7890-abcd-ef1234567890","status":"cancelado"}'

SIG=$(echo -n "$BODY" | openssl dgst -sha256 -hmac "seu_segredo_aqui" -hex | awk '{print $2}')

curl -s -X POST https://seuservidor.com/api/pagamentos/externos \
  -H "Content-Type: application/json" \
  -H "X-Signature: $SIG" \
  -d "$BODY"
```

**Resposta `200 OK`:**

```json
{
  "success":      true,
  "mensagem":     "Pagamento confirmado com sucesso",
  "pagamento_id": "a1b2c3d4-e5f6-7890-abcd-ef1234567890"
}
```

---

### `GET /api/pagamento/status/{id}`

Consulta o status atual de um pagamento. Use como **fallback** caso a notificação automática não chegue.

```bash
curl -s https://seuservidor.com/api/pagamento/status/a1b2c3d4-e5f6-7890-abcd-ef1234567890
```

**Resposta — pendente:**

```json
{
  "id":        "a1b2c3d4-e5f6-7890-abcd-ef1234567890",
  "status":    "pendente",
  "valor":     49.90,
  "pago":      false,
  "expira_em": "2025-03-15T15:30:00Z"
}
```

**Resposta — confirmado:**

```json
{
  "id":     "a1b2c3d4-e5f6-7890-abcd-ef1234567890",
  "status": "pago",
  "valor":  49.90,
  "pago":   true
}
```

---

## Notificação Automática (Fluxo Principal)

Após a confirmação pelo gateway, o servidor envia `POST` automaticamente para **todas as URLs** configuradas em `./data/external_notify_url.json`.

### Corpo recebido

```json
{
  "evento":        "pagamento.confirmado",
  "versao":        "1.0",
  "timestamp":     "2025-03-15T14:32:00Z",
  "pagamento_id":  "a1b2c3d4-e5f6-7890-abcd-ef1234567890",
  "txid":          "abc123def456ghi789",
  "valor":         49.90,
  "status":        "pago",
  "gateway":       "efi",
  "plano_tipo":    "mensal",
  "plano_dias":    30,
  "cliente_nome":  "João da Silva",
  "cliente_email": "joao@email.com",
  "cliente_tel":   "11999998888",
  "origem":        "externo",
  "expira_em":     "2025-03-15T15:30:00Z"
}
```

### Validando a assinatura recebida

O servidor assina o POST com o header `X-Signature`. Valide antes de processar:

```bash
BODY='<corpo_exato_recebido>'
SIG_RECEBIDO='<valor_do_header_X-Signature>'
SECRET="seu_segredo_aqui"

SIG_ESPERADO=$(echo -n "$BODY" | openssl dgst -sha256 -hmac "$SECRET" -hex | awk '{print $2}')

if [ "$SIG_RECEBIDO" = "$SIG_ESPERADO" ]; then
  echo "✅ Assinatura válida — processar"
else
  echo "❌ Assinatura inválida — rejeitar"
fi
```

### Boas práticas para o endpoint receptor

- **Responda `HTTP 200` imediatamente** e processe de forma assíncrona. O servidor não faz reenvio automático em caso de falha.
- **Valide sempre a assinatura** antes de liberar qualquer acesso.
- **Salve o `pagamento_id`** para reconciliação e evitar processamento duplicado.
- Use `/api/pagamento/status/{id}` como fallback se a notificação não chegar.

---

## Idempotência

Para evitar cobranças duplicadas em retentativas por timeout, envie o header `X-Idempotency-Key` com um valor único por operação. Requisições repetidas com a mesma chave retornam a resposta original sem gerar nova cobrança.

```bash
curl -s -X POST https://seuservidor.com/api/pagamentos/externos/iniciar \
  -H "Content-Type: application/json" \
  -H "X-Signature: $SIG" \
  -H "X-Idempotency-Key: pedido-12345-2025-03-15" \
  -d "$BODY"
```

Quando uma chave já processada é reenviada, a resposta inclui o header:

```
X-Idempotent-Replay: true
```

---

## Respostas de Erro

Todos os erros seguem o formato:

```json
{ "error": "mensagem descritiva do problema" }
```

| HTTP | Situação | Exemplos de mensagem |
|---|---|---|
| `400` | Dados inválidos ou ausentes | `"cliente_email inválido"`, `"valor mínimo é R$ 0,50"`, `"plano_tipo é obrigatório"` |
| `401` | Assinatura ausente ou inválida | `"X-Signature obrigatório"`, `"assinatura inválida"` |
| `405` | Método HTTP incorreto | `"método não permitido"` |
| `429` | Rate limit atingido | `"muitas requisições, aguarde antes de tentar novamente"` |
| `502` | Falha na comunicação com o gateway PIX | `"erro ao gerar cobrança PIX, tente novamente"` |

> O rate limit é de **10 requisições por minuto** por IP para os endpoints externos.

---

## Exemplo Completo — Fluxo de Ponta a Ponta

```bash
#!/bin/bash
# Fluxo completo: criar cobrança → exibir QR → verificar status

SERVER="https://seuservidor.com"
SECRET="seu_segredo_aqui"

# Função auxiliar para gerar assinatura
sign() {
  echo -n "$1" | openssl dgst -sha256 -hmac "$SECRET" -hex | awk '{print $2}'
}

echo "=== 1. Criando cobrança PIX ==="

BODY=$(cat <<'EOF'
{
  "cliente_nome":  "João da Silva",
  "cliente_email": "joao@email.com",
  "cliente_tel":   "11999998888",
  "plano_tipo":    "mensal",
  "valor":         49.90,
  "plano_dias":    30
}
EOF
)

SIG=$(sign "$BODY")

RESP=$(curl -s -X POST "$SERVER/api/pagamentos/externos/iniciar" \
  -H "Content-Type: application/json" \
  -H "X-Signature: $SIG" \
  -H "X-Idempotency-Key: $(uuidgen)" \
  -d "$BODY")

echo "$RESP" | python3 -m json.tool

# Extrai campos da resposta
ID=$(echo "$RESP"  | python3 -c "import sys,json; print(json.load(sys.stdin)['id'])")
EMV=$(echo "$RESP" | python3 -c "import sys,json; print(json.load(sys.stdin)['payload_emv'])")

echo ""
echo "=== 2. Dados para o cliente ==="
echo "ID do pagamento : $ID"
echo "Copia e cola PIX: $EMV"

echo ""
echo "=== 3. Verificando status (fallback) ==="
curl -s "$SERVER/api/pagamento/status/$ID" | python3 -m json.tool
```
