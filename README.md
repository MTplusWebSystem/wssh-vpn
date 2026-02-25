# API de Pagamentos PIX — Integração Externa

Documentação para integração com o módulo de pagamentos do servidor **wssh-vpn**.

---

## Visão Geral

O fluxo é simples:

1. Sua app chama `/api/pagamentos/externos/iniciar` → recebe QR Code
2. Cliente paga via app bancário
3. Gateway confirma → servidor envia **POST automático** para sua URL (`pix_external_notify_url`)
4. Sua app recebe a notificação e faz o que quiser com ela

O servidor **não cria usuários VPN** para pagamentos externos. Ele só processa o pagamento e te avisa.

---

## Configuração necessária no servidor

| Variável | Descrição |
|---|---|
| `pix_external_notify_url` | URL da sua app que recebe o POST após confirmação |
| `pix_webhook_secret` | Segredo HMAC-SHA256 compartilhado (recomendado) |

---

## Autenticação

Todas as requisições para endpoints externos devem incluir o cabeçalho `X-Signature` quando `pix_webhook_secret` estiver configurado.

A assinatura é o **HMAC-SHA256 do corpo** em hexadecimal:

```bash
# Gerar assinatura do body
BODY='{"cliente_nome":"João","cliente_email":"joao@email.com","plano_tipo":"mensal","valor":49.90}'
SECRET="seu_segredo_aqui"

SIG=$(echo -n "$BODY" | openssl dgst -sha256 -hmac "$SECRET" -hex | awk '{print $2}')
echo $SIG
```

---

## Endpoints

### `POST /api/pagamentos/externos/iniciar`

Cria uma cobrança PIX. Valor definido por você, `plano_tipo` é rótulo livre para exibição no seu painel.

**Campos do corpo:**

| Campo | Obrigatório | Descrição |
|---|---|---|
| `cliente_nome` | Sim | Nome do cliente |
| `cliente_email` | Sim | E-mail do cliente |
| `cliente_tel` | Não | Telefone |
| `plano_tipo` | Sim | Rótulo livre (ex: `"mensal"`, `"gold"`) |
| `valor` | Sim | Valor em reais — mín. `0.50`, máx. `10000.00` |
| `plano_dias` | Não | Informativo — enviado na notificação |

**Curl:**

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
  -H "X-Idempotency-Key: pedido-uuid-$(date +%s)" \
  -d "$BODY"
```

**Resposta de sucesso (`200`):**

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

> **Guarde o campo `id`** — você vai precisar dele para rastreamento e reconciliação.

---

### `POST /api/pagamentos/externos`

Notifica o servidor sobre confirmação ou cancelamento de um pagamento já criado. Use quando sua app receber a confirmação por outro canal além do gateway.

**Curl — confirmar:**

```bash
BODY=$(cat <<'EOF'
{
  "pagamento_id": "a1b2c3d4-e5f6-7890-abcd-ef1234567890",
  "status":       "pago",
  "observacoes":  "Confirmado via checkout próprio"
}
EOF
)

SECRET="seu_segredo_aqui"
SIG=$(echo -n "$BODY" | openssl dgst -sha256 -hmac "$SECRET" -hex | awk '{print $2}')

curl -s -X POST https://seuservidor.com/api/pagamentos/externos \
  -H "Content-Type: application/json" \
  -H "X-Signature: $SIG" \
  -d "$BODY"
```

**Curl — cancelar:**

```bash
BODY='{"pagamento_id":"a1b2c3d4-e5f6-7890-abcd-ef1234567890","status":"cancelado"}'

SIG=$(echo -n "$BODY" | openssl dgst -sha256 -hmac "seu_segredo_aqui" -hex | awk '{print $2}')

curl -s -X POST https://seuservidor.com/api/pagamentos/externos \
  -H "Content-Type: application/json" \
  -H "X-Signature: $SIG" \
  -d "$BODY"
```

**Curl — confirmar por txid** (alternativa ao `pagamento_id`):

```bash
BODY='{"txid":"abc123def456ghi789","status":"pago"}'

SIG=$(echo -n "$BODY" | openssl dgst -sha256 -hmac "seu_segredo_aqui" -hex | awk '{print $2}')

curl -s -X POST https://seuservidor.com/api/pagamentos/externos \
  -H "Content-Type: application/json" \
  -H "X-Signature: $SIG" \
  -d "$BODY"
```

**Resposta de sucesso (`200`):**

```json
{
  "success":      true,
  "mensagem":     "Pagamento confirmado com sucesso",
  "pagamento_id": "a1b2c3d4-e5f6-7890-abcd-ef1234567890"
}
```

---

### `GET /api/pagamento/status/{id}`

Consulta o status atual de um pagamento. Use como fallback caso a notificação automática não chegue.

```bash
curl -s https://seuservidor.com/api/pagamento/status/a1b2c3d4-e5f6-7890-abcd-ef1234567890
```

**Resposta pendente:**

```json
{
  "id":        "a1b2c3d4-e5f6-7890-abcd-ef1234567890",
  "status":    "pendente",
  "valor":     49.90,
  "pago":      false,
  "expira_em": "2025-03-15T15:30:00Z"
}
```

**Resposta após confirmação:**

```json
{
  "id":     "a1b2c3d4-e5f6-7890-abcd-ef1234567890",
  "status": "pago",
  "valor":  49.90,
  "pago":   true
}
```

---

## Notificação automática (Fluxo principal)

Quando o cliente paga, o gateway confirma via webhook → o servidor envia automaticamente um `POST` para `pix_external_notify_url`.

**Corpo recebido pela sua app:**

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
  "cliente_nome":  "João da Silva",
  "cliente_email": "joao@email.com",
  "cliente_tel":   "11999998888",
  "origem":        "externo",
  "expira_em":     "2025-03-15T15:30:00Z"
}
```

O servidor assina o POST com `X-Signature` (HMAC-SHA256). Valide assim:

```bash
# Simular validação do webhook recebido
BODY='<body_recebido>'
SIG_RECEBIDO='<valor_do_header_X-Signature>'
SECRET="seu_segredo_aqui"

SIG_ESPERADO=$(echo -n "$BODY" | openssl dgst -sha256 -hmac "$SECRET" -hex | awk '{print $2}')

if [ "$SIG_RECEBIDO" = "$SIG_ESPERADO" ]; then
  echo "Assinatura válida"
else
  echo "Assinatura inválida — rejeitar"
fi
```

> **Responda com HTTP 200 imediatamente** e processe de forma assíncrona. O servidor não faz reenvio automático em caso de falha.

---

## Respostas de erro

| HTTP | Motivo | Mensagem |
|---|---|---|
| `400` | Dados inválidos | `"cliente_email inválido"`, `"valor mínimo é R$ 0,50"` |
| `401` | Sem assinatura ou HMAC inválido | `"X-Signature obrigatório"`, `"assinatura inválida"` |
| `405` | Método HTTP errado | `"método não permitido"` |
| `429` | Rate limit (10 req/min por IP) | `"muitas requisições, aguarde antes de tentar novamente"` |
| `502` | Falha no gateway PIX | `"erro ao gerar cobrança PIX, tente novamente"` |

---

## Exemplo completo — fluxo de ponta a ponta

```bash
#!/bin/bash
# Exemplo: criar cobrança e verificar status

SERVER="https://seuservidor.com"
SECRET="seu_segredo_aqui"

sign() {
  echo -n "$1" | openssl dgst -sha256 -hmac "$SECRET" -hex | awk '{print $2}'
}

# 1. Criar cobrança
BODY='{"cliente_nome":"João da Silva","cliente_email":"joao@email.com","plano_tipo":"mensal","valor":49.90}'
SIG=$(sign "$BODY")

RESP=$(curl -s -X POST "$SERVER/api/pagamentos/externos/iniciar" \
  -H "Content-Type: application/json" \
  -H "X-Signature: $SIG" \
  -H "X-Idempotency-Key: $(uuidgen)" \
  -d "$BODY")

echo "Resposta: $RESP"

ID=$(echo "$RESP" | python3 -c "import sys,json; print(json.load(sys.stdin)['id'])")
EMV=$(echo "$RESP" | python3 -c "import sys,json; print(json.load(sys.stdin)['payload_emv'])")

echo ""
echo "ID do pagamento : $ID"
echo "Copia e cola PIX: $EMV"

# 2. Verificar status (fallback — normalmente você recebe a notificação automática)
echo ""
echo "Status atual:"
curl -s "$SERVER/api/pagamento/status/$ID" | python3 -m json.tool
```

---

## Idempotência

Para evitar cobranças duplicadas em caso de retentativa por timeout, envie o header `X-Idempotency-Key` com um valor único por operação (ex: UUID do seu pedido). Requisições repetidas com a mesma chave retornam a resposta original sem gerar nova cobrança.

```bash
curl -s -X POST https://seuservidor.com/api/pagamentos/externos/iniciar \
  -H "Content-Type: application/json" \
  -H "X-Signature: $SIG" \
  -H "X-Idempotency-Key: pedido-12345-2025-03-15" \
  -d "$BODY"
```
