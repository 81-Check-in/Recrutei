# Recrutei — Backend

Rotina diária que lê a caixa de e-mail, extrai currículos, avalia com IA
e grava no Supabase.

```
E-mail (IMAP)  →  Extração  →  Classificação  →  Avaliação  →  Supabase
                  PDF/DOCX      Claude Haiku     Claude Sonnet
                  OCR/GDocs     é currículo?     nota + análise
                                qual vaga?
```

---

## 1. Instalação local

```bash
python -m venv .venv
source .venv/bin/activate        # Windows: .venv\Scripts\activate
pip install -r requirements.txt
```

### Dependências do sistema (para OCR)

O OCR só funciona com estes programas instalados:

| Sistema | Comando |
|---|---|
| Ubuntu/Debian | `sudo apt install tesseract-ocr tesseract-ocr-por poppler-utils` |
| macOS | `brew install tesseract tesseract-lang poppler` |
| Windows | [Tesseract](https://github.com/UB-Mannheim/tesseract/wiki) + [Poppler](https://github.com/oschwartz10612/poppler-windows/releases) |

Sem eles o sistema roda normalmente — currículos escaneados vão para a
fila de exceções em vez de serem lidos.

---

## 2. Configuração

```bash
cp .env.example .env
```

Preencha o `.env`:

| Variável | Onde obter |
|---|---|
| `SUPABASE_SERVICE_KEY` | Supabase → Project Settings → API → `service_role` |
| `ANTHROPIC_API_KEY` | console.anthropic.com → API Keys |
| `IMAP_USUARIO` / `IMAP_SENHA` | conta de e-mail dedicada a currículos |
| `IDENTIDADE_CHAVE` | gere com `python -c "import secrets; print(secrets.token_hex(32))"`. Guarde-a: se mudar, reenvios antigos deixam de ser detectados |

> A `service_role` ignora todas as políticas de segurança do banco.
> Nunca coloque no frontend, nunca faça commit.

---

## 3. Primeiro uso

**Passo 1 — testar as conexões**

```bash
python main.py --testar
```

Verifica Supabase, IMAP e Claude. Só siga adiante se as três passarem.

**Passo 2 — simular sem gravar**

```bash
python main.py --simular --limite 5
```

Lê 5 e-mails, mostra o que faria, não grava nada e não move mensagens.
Use para conferir se a extração e a classificação estão corretas.

**Passo 3 — rodar de verdade, com poucos e-mails**

```bash
python main.py --limite 10
```

Confira o resultado no sistema web antes de liberar o volume completo.

**Passo 4 — execução normal**

```bash
python main.py
```

### Outros comandos

```bash
python main.py --manutencao     # só inativação e expurgo (LGPD)
```

---

## 4. Deploy no Railway

1. Suba a pasta para um repositório no GitHub (o `.gitignore` já protege o `.env`).
2. No Railway: **New Project → Deploy from GitHub repo**.
3. Em **Variables**, cadastre todas as variáveis do `.env`.
4. Em **Settings → Cron Schedule**, defina:

```
0 8 * * *
```

Isso executa todo dia às 05h no horário de Brasília (o Railway usa UTC).
O `nixpacks.toml` já instala Tesseract e Poppler automaticamente.

---

## 5. O que cada arquivo faz

| Arquivo | Responsabilidade |
|---|---|
| `main.py` | Entrada, argumentos de linha de comando |
| `pipeline.py` | Orquestra o fluxo completo |
| `leitor_email.py` | IMAP: busca, lê e move mensagens |
| `extrator.py` | PDF, DOCX, OCR e Google Docs → texto |
| `ia.py` | Chamadas ao Claude (classificação e avaliação) |
| `database.py` | Acesso ao Supabase |
| `utils.py` | Telefone, hash de identidade, limpeza de texto |
| `config.py` | Variáveis de ambiente e constantes |

---

## 6. Decisões importantes

**Idempotência** — cada e-mail é registrado pelo `Message-ID`. Rodar duas
vezes não gera duplicata.

**Nada é descartado em silêncio** — todo e-mail que não vira candidatura
entra na fila de exceções, visível no sistema web.

**Segunda opinião** — notas entre 60 e 75 recebem uma segunda avaliação
independente. Divergência acima de 10 pontos é sinalizada para revisão
humana. Para desativar (cada currículo passa a ser avaliado uma vez só),
use o interruptor em Configurações → Avaliação por IA; por baixo ele deixa
`faixa_ambigua_min` e `faixa_ambigua_max` vazias. O log de cada execução
informa se está ativa.

**Requisito obrigatório limita a nota** — faltando qualquer obrigatório,
a nota não passa de 45, e o candidato aparece marcado como fora do perfil.
Ele continua visível: quem decide é o RH.

**LGPD** — o prompt de avaliação proíbe explicitamente considerar idade,
gênero, origem, religião ou qualquer característica protegida. A rotina
de manutenção roda junto com o pipeline: inativa após 2 meses sem
movimentação e expurga os dados pessoais após 4 meses inativo. Antes de
ir para a IA, e-mail, telefone e documentos (CPF, RG, CNH, CEP) são
trocados por marcadores, e o nome também é ocultado na avaliação. O hash
que detecta reenvios é um HMAC com chave secreta (`IDENTIDADE_CHAVE`),
não um SHA-256 simples, para que o expurgo não possa ser desfeito por
força bruta.

**Custo** — cada execução registra tokens e custo estimado na tabela
`execucoes_pipeline`, visível no sistema.

**Modelos** — a classificação e a avaliação podem usar Fable 5.1, Opus 5,
Sonnet 5 ou Haiku 4.5 (Configurações → Avaliação por IA, que mostra uma
estimativa em US$ a cada troca). Sonnet 5, Opus 5 e Fable 5.1 raciocinam
por padrão e o raciocínio é cobrado como saída: o Sonnet 5 roda com o
raciocínio desligado e o Opus 5/Fable 5.1 com esforço baixo (ver
`PARAMETROS_MODELO` em `config.py`). Ao acrescentar um modelo novo, inclua-o
em `PRECOS` (`config.py`) e em `MODELOS_IA` (`recrutei.html`); modelo fora da
tabela funciona, mas o custo aparece como US$ 0,00.

---

## 7. Limitações conhecidas

- **Google Docs privado**: só funciona se o candidato liberou o
  compartilhamento público. Caso contrário vai para exceções.
- **Arquivos `.doc` antigos** (Word 97-2003) podem falhar na extração.
- **Telefone com código de operadora** (`011 61 9...`) é ambíguo e pode
  ser normalizado incorretamente. Raro em currículos.
- **OCR** depende da qualidade da imagem. Fotos tortas ou de baixa
  resolução vão para exceções.

---

## 8. Se algo der errado

| Sintoma | Causa provável |
|---|---|
| `Variável de ambiente obrigatória não definida` | Falta preencher o `.env` |
| IMAP falha ao conectar | Senha incorreta ou IMAP bloqueado no painel da Locaweb |
| Tudo vira "vaga_nao_identificada" | Nenhuma vaga cadastrada, ou requisitos vagos demais |
| OCR nunca funciona | Tesseract não instalado |
| `row-level security` no log | Está usando a chave `anon` em vez da `service_role` |

Toda execução fica registrada em `execucoes_pipeline`, com erro e custo.
