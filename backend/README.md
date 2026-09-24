# Recrutei — Backend

Rotina diária que lê a caixa de e-mail, extrai currículos, coloca cada candidato no **Banco de Talentos**,
analisa com IA e grava no Supabase. O RH atribui candidatos às vagas pelo painel.

```
E-mail (IMAP)  →  Extração  →  Identificação  →  Banco de Talentos  →  Análise da IA
                  PDF/DOCX      Claude Haiku      candidato único       Claude Sonnet
                  OCR/GDocs     é currículo?      (reaproveita se       pontos + / −
                                nome, cidade      já existe)            Área/Cargo/Nível

RH (painel)  →  atribui o candidato a uma vaga  →  avaliação (nota) para aquela vaga
                reprovado / cancelado           →  volta sozinho ao Banco de Talentos
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
| `SMTP_*`, `PAINEL_URL` | **opcionais** — só para o e-mail de aviso da sanitização (ver seção 7) |

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
Use para conferir se a extração e a identificação estão corretas.

**Passo 3 — rodar de verdade, com poucos e-mails**

```bash
python main.py --limite 10
```

Confira o resultado no sistema web (Banco de Talentos) antes de liberar o volume completo.

**Passo 4 — execução normal**

```bash
python main.py
```

**Caixa com e-mails antigos acumulados?** O pipeline lê os não lidos do mais
antigo para o mais novo, então um acúmulo grande vai na frente dos candidatos
novos (o `LIMITE_EMAILS` sozinho não resolve). Defina `IMAP_DESDE=AAAA-MM-DD`
no `.env` para processar só o que chegou a partir dessa data. Os antigos
continuam não lidos e podem ser tratados depois, recuando a data.

### Outros comandos

```bash
python main.py --manutencao             # só a manutenção (partições da auditoria e arquivos de dados excluídos)
python main.py --reanalisar             # só as (re)análises da IA pedidas: candidatos migrados, currículo reenviado, botão "Reanalisar"
python main.py --reavaliar              # (sem uso desde a 033: atribuir a vaga não pede mais avaliação da IA)
python main.py --reprocessar-excecoes   # só as exceções marcadas para tentar de novo no painel
python main.py --uploads-manuais        # só os currículos enviados manualmente no painel
python main.py --sanitizacao            # gera a lista de sugestões de sanitização se o intervalo venceu (e avisa o RH)
python main.py --sanitizacao --forcar   # gera agora, mesmo antes do prazo
python main.py --desde 2026-09-18       # só e-mails recebidos a partir da data (o mesmo que IMAP_DESDE, só nesta execução)
python main.py --reler-caixa --desde 2026-06-25 --ate-uid 195303
                                        # relê a caixa (lidos e não lidos) e recarrega o Banco de Talentos — veja a seção 6.1
```

`--enriquecer` deixou de existir: a reanálise (`--reanalisar`) já completa idade, escolaridade,
experiência e CNH de quem ainda não tem.

---

## 4. Deploy no Railway

1. Suba o projeto para um repositório no GitHub (o `.gitignore` já protege o `.env`).
2. No Railway: **New Project → Deploy from GitHub repo**.
3. Em **Settings → Source → Root Directory**, defina `backend`. O repositório tem
   `backend/` e `frontend/`; sem isso o Railway não encontra o `Dockerfile`.
4. Em **Variables**, cadastre as variáveis do `.env`, **sem aspas** em volta dos valores.
   Confira estas:
   - `MODO_SIMULACAO=false` (em `true` nada é gravado).
   - `LIMITE_EMAILS`: deixe `0` ou vazio para processar tudo; use um número pequeno
     só no primeiro dia.
   - `IDENTIDADE_CHAVE`: a **mesma** usada até hoje. Se mudar, reenvios antigos
     deixam de ser detectados.
5. Em **Settings → Cron Schedule**, defina:

```
0 8 * * *
```

Isso executa todo dia às 05h no horário de Brasília (o Railway usa UTC).
O `Dockerfile` instala Tesseract (com o idioma português) e Poppler. A execução roda
uma vez e encerra; se falhar, o Railway marca a execução com erro.

**A sanitização não precisa de agendamento próprio.** Ela roda dentro desta mesma execução diária:
todo dia o sistema só pergunta ao banco "o intervalo (2 meses) venceu?" e, se sim, gera a lista
de sugestões e avisa o RH. Fora do prazo não faz nada. (O Supabase deste projeto não tem `pg_cron`.)

Para testar a imagem localmente antes do deploy:

```bash
docker build -t recrutei-backend .
docker run --rm -v "$PWD/.env:/app/.env:ro" recrutei-backend python main.py --testar
```

Não use `--env-file .env` nesse teste: o Docker não remove aspas, então senhas
entre aspas (ou com `#`) chegam erradas.

---


## 5. Banco de Talentos — como funciona

**Antes:** o candidato nascia preso a uma vaga (a IA escolhia qual) e ficava ali.
**Agora:** o candidato é uma pessoa, uma vez só, independente de vaga. O vínculo com vaga virou **histórico**.

| Tabela | O que é |
|---|---|
| `candidatos` | A pessoa: dados pessoais, situação no banco (`status_banco`), sugestão atual da IA, datas. Entidade central e persistente |
| `analises_ia` | Histórico de análises por candidato (pontos positivos/negativos, área/cargo/nível sugeridos, confiança, modelo, versão do prompt). A mais recente vale |
| `candidaturas` | O vínculo **candidato ↔ vaga** (N:N). Uma linha por atribuição: status, quem atribuiu, quando, resultado final. Reprovar aqui **não** apaga o candidato |
| `curriculos` | Currículos do candidato (várias versões; um é o `atual`), com o e-mail de origem |
| `avaliacoes` | Nota da IA do candidato **para uma vaga** — só existe depois que o RH atribui |
| `sanitizacao_ciclos` / `sanitizacao_sugestoes` | A fila e o histórico de decisões da sanitização |

**Situação do candidato (`status_banco`):** `ativo` (disponível para atribuir) · `em_processo` (tem candidatura aberta) ·
`inativo` (fora da lista por decisão do RH, ou contratado) · `expurgado` (dados pessoais apagados; sobram só o hash de identidade e as métricas).

**Status da candidatura:** `aguardando` (atribuída, sem entrevista) → `entrevista_agendada` → `entrevista_realizada` /
`aprovado` / `reprovado` / `nao_compareceu` → `contratado`. Fecham a candidatura: `reprovado`, `cancelado`, `descartado`, `contratado`.

### O caminho de um currículo

1. **Entra** por e-mail ou pelo botão "Enviar currículo": extração do texto, e a IA (Haiku) só confirma que é currículo e lê nome e cidade.
   O **endereço que enviou** o e-mail e a **data do envio** (cabeçalhos `From` e `Date`) ficam gravados no próprio currículo (`email_envio` e
   `recebido_em`) e aparecem no painel — vêm do e-mail, não da IA, então existem mesmo quando a análise falha ou o currículo não traz e-mail.
   Não escolhe vaga. Nenhum e-mail vira exceção por "vaga não identificada" (esse motivo deixou de existir).
2. **Vira candidato.** Se a pessoa já está no banco (mesmo hash de nome+telefone; ou mesmo e-mail e mesmo nome), o currículo novo
   vira a versão **atual** dela e a análise só é refeita se o texto mudou. Quem estava inativo ou excluído e reenviou o currículo volta a `ativo`.
3. **É qualificada** (Sonnet, uma vez por currículo, sem olhar vaga nenhuma): a IA escolhe o **setor**, a **função** e o **nível** que a
   experiência indica, entre os valores das tabelas `setores`, `funcoes_setor` e `niveis_funcao`, e devolve resumo, pontos fortes, lacunas e
   rotatividade. O resultado é gravado no próprio currículo (`setor_adequado`, `funcao_setor`, `nivel_funcao`) e copiado para o candidato
   (Área / Cargo / Nível do painel). Setor, função ou nível sem classificação → **"revisão manual necessária"**. Detalhes na seção 11.
4. **O RH atribui** o candidato a uma vaga aberta, na tela **Banco de Talentos → Atribuir**, que mostra lado a lado a sugestão da IA e os dados
   da vaga. A sugestão é só apoio (área diferente do setor da vaga só gera um aviso). Só candidatos `ativo` podem ser atribuídos e
   **cada candidato tem no máximo uma candidatura aberta**. A atribuição pede a avaliação para aquela vaga, que sai na próxima execução.
5. **Reprovou ou cancelou?** A candidatura fecha e o candidato **volta sozinho** a `ativo` (regra no banco, vale para o painel e para SQL).
   O histórico da tentativa fica guardado. Contratado sai do banco (`inativo`, retenção permanente, nunca entra na sanitização).

---

## 6. Colocando o Banco de Talentos no ar (migração)

A mudança altera o banco, o pipeline e o painel **juntos**: aplique tudo na mesma janela. Os arquivos em `backend/sql/` são
executados **um por vez, nesta ordem**, no Supabase → SQL Editor:

| Arquivo | O que faz |
|---|---|
| `020_banco_talentos_tipos.sql` | Valores novos nos tipos existentes (`aguardando`, `cancelado`, ações de auditoria). Precisa rodar sozinho |
| `021_banco_talentos_modelo.sql` | Tabelas `candidatos` e `analises_ia`, colunas novas, **índices de busca**, RLS |
| `022_banco_talentos_regras.sql` | Gatilhos e funções: atribuir, devolver ao banco, editar, contato, consentimento, inativar |
| `023_banco_talentos_sanitizacao.sql` | Sanitização (tabelas, parâmetros, cálculo, decisão em lote) e **fim da retenção automática** |
| `024_banco_talentos_views.sql` | Views novas e a busca; remove `vw_triagem` e `filtrar_triagem` |
| `025_banco_talentos_migracao_dados.sql` | **Migra o que existe hoje**, atômico e com verificações |
| `026_banco_talentos_ajustes.sql` | Ajustes dos avisos do Supabase (`search_path` de `norm_busca`, índices nas chaves estrangeiras, políticas de `usuarios` fundidas). Não muda dados nem comportamento |
| `037_candidatos_da_vaga_views.sql` | Só acrescenta colunas a `vw_candidatos` e `vw_candidaturas` (vaga, qualificação e nota do currículo) para a tela "Candidatos em processo" por vaga. Rodar depois da 036 |
| `036_niveis_habilitar_desabilitar.sql` | `alterar_nivel_funcao()` (só administrador): habilita/desabilita Jovem Aprendiz e Trainee e reescreve o critério de qualquer nível, com auditoria; a vaga só aceita nível habilitado. Rodar depois da 035 |
| `035_catalogo_setores_cargos_niveis.sql` | O catálogo real: níveis (Jovem Aprendiz, Trainee, Júnior, Pleno, Sênior), 13 setores e 51 cargos, `funcoes_setor.aceita_iniciante` e a regra do nível na vaga. Rodar depois da 034 |
| `034_atribuir_grava_qualificacao.sql` | Atribuir um candidato a uma vaga completa grava o setor, a função e o nível da vaga no currículo atual (e no candidato), sem IA. Rodar depois da 033 |
| `033_selecao_por_qualificacao.sql` | Seleção de CVs por vaga: `curriculos.nota_classificacao`, `vagas.funcao_setor` e `vagas.nivel_funcao`, `selecionar_curriculos_vaga()` (filtro exato por setor + função + nível, ordenado pela nota), contagem "No banco" do card; atribuir a vaga deixa de pedir avaliação da IA. Rodar depois da 032 |
| `032_email_de_envio.sql` | `curriculos.email_envio` (quem enviou), preenchido para os currículos existentes a partir de `remetentes`; o expurgo também o apaga; a view do banco ganha `curriculo_email_envio`. Rodar depois da 031 |
| `031_qualificacao_curriculo.sql` | Qualificação do currículo: tabelas `niveis_funcao` e `funcoes_setor` (com carga inicial), colunas `setor_adequado`, `funcao_setor` e `nivel_funcao` em `curriculos`, e um ajuste na sanitização (seção 11). **Aplique antes de publicar o backend**: sem as tabelas a análise fica adiada |

**Roteiro:**

1. **Backup** (Supabase → Database → Backups) e **pause o cron** da rotina no Railway. O pipeline antigo não funciona no schema novo e o novo
   não funciona no antigo.
2. **Ensaie** (recomendado): no SQL Editor, cole `BEGIN;`, o conteúdo do `025` sem o `COMMIT` final e `ROLLBACK;` — como foi feito na `016`.
   Ou rode `backend/sql/ensaio/ensaio.sh` (seção 12), que ensaia tudo em um Postgres descartável.
3. Rode `020` → `021` → `022` → `023` → `024` → `025` → `026`. O `025` aborta **sem mudar nada** se qualquer verificação falhar
   (totais de candidaturas, currículos, avaliações e entrevistas iguais; nenhum candidato órfão; um currículo atual por candidato…).
   Todos podem ser reexecutados sem problema.
4. Publique o backend (Railway) e o painel (Vercel). Retome o cron.
5. Rode `python main.py --reanalisar`: refaz a análise (Área/Cargo/Nível) dos candidatos migrados. Até lá, eles aparecem com "IA analisando…".
   Custo aproximado: uma chamada do modelo de avaliação por candidato.
6. Rode `verificar_seguranca.sql`: todas as linhas devem dar `false`.

**O que a migração faz com os dados de hoje** (nada é apagado):

| Antes | Depois |
|---|---|
| Uma candidatura por e-mail recebido | Um **candidato** por pessoa (duplicatas fundidas pelo hash de identidade); cada currículo vira uma versão dele |
| `recebido` / `em_analise` / `avaliado` (vaga escolhida pela IA, sem decisão do RH) | Candidato `ativo` no banco. O vínculo antigo vira candidatura `cancelado` com origem `triagem_legada` (histórico), com as avaliações preservadas |
| `selecionado` | `aguardando` |
| `entrevista_agendada`, `entrevista_realizada`, `aprovado`, `nao_compareceu` | Continuam como estão; candidato `em_processo` |
| `reprovado` | Candidatura encerrada; o candidato volta a `ativo` |
| `contratado` | Encerrada; candidato `inativo` com retenção permanente |
| `descartado` (o RH descartou o currículo) | Candidatura `cancelado`; candidato `inativo` (continua fora da lista de disponíveis) |
| Dados pessoais no JSON da candidatura | Em `candidatos`; o JSON antigo é esvaziado (não ficam duas cópias — LGPD) |

Cada candidato migrado começa com uma análise inicial (copiada da última avaliação; a área vem do setor da vaga que a IA antiga escolhera),
marcada como "revisão manual", e com a reanálise pedida.

> O `025` **recusa** migrar se algum candidato tiver duas candidaturas abertas ao mesmo tempo (o modelo novo permite uma) e diz qual.

### 6.1 Zerar e recarregar (recomeço limpo)

Em vez de conviver com os dados migrados (análises marcadas como "revisão manual", vínculos `triagem_legada`), dá para **zerar** o banco de
talentos e **recarregar** os currículos direto dos e-mails, já no modelo novo. Foi o que se fez em produção em 2026-09-24
(102 candidatos, 109 candidaturas, 127 avaliações e 5 entrevistas foram apagados; 140 e-mails relidos).

**1. `sql/zerar_banco_talentos.sql`** — **irreversível** (só o backup do Supabase recupera). Uma transação: se qualquer verificação falhar, nada é apagado.
Vem com uma trava (`'NAO'` na linha marcada no início) que precisa ser trocada por `'SIM'`.

| Apaga | Mantém |
|---|---|
| candidatos, currículos, análises da IA · candidaturas (com avaliações e entrevistas, por cascata) · exceções · uploads manuais · remetentes livres · ciclos e sugestões de sanitização | vagas (requisitos, empresas) · usuários · configurações, **inclusive o marcador do e-mail** (`imap_ultimo_uid`) · remetentes **bloqueados** · auditoria (que ganha o registro da operação) · histórico de execuções |

- O marcador do e-mail fica de propósito: sem ele a execução diária releria a caixa desde o começo.
- Os arquivos do Storage **não** são apagados pelo SQL: os caminhos entram em `arquivos_para_remover` e o backend os remove na próxima
  execução (`python main.py --manutencao`, ou a execução diária). Os caminhos são únicos por envio (`AAAA/MM/<uuid>`), então recarregar antes ou
  depois da remoção não faz o backend apagar um arquivo novo.

**2. `python main.py --reler-caixa --desde AAAA-MM-DD --ate-uid N`** — recarrega no modelo novo:

- lê **lidos e não lidos** desde a data, do mais antigo ao mais novo, e passa cada e-mail pelo mesmo caminho da execução diária;
- **não altera a caixa** (abre em somente leitura; nada é marcado como lido);
- **pode ser repetido ou retomado**: e-mail já importado é reconhecido pelo Message-ID e ignorado;
- **recusa rodar sem data inicial** (leria a caixa inteira). O `LIMITE_EMAILS` do `.env` (que serve à execução diária) **não vale** aqui: use `--limite N`;
- `--ate-uid` é o teto. Use o valor de `imap_ultimo_uid` para reler **só o que o pipeline já tinha lido**; o que veio depois continua na fila da execução diária;
- o marcador do e-mail só avança, nunca recua.

Escolha a data pelo currículo mais antigo (`select min(recebido_em) from curriculos`, **antes** de zerar). Custo: cerca de US$ 0,02 por e-mail
(identificação + análise; mais se houver OCR). Em produção: 140 e-mails, ~1 h, ~US$ 2,5.

**Antes de zerar:** faça o backup, pause o cron e confira a ordem: zerar → `--manutencao` → `--reler-caixa`. O ensaio (`ensaio.sh`, passo 6) cobre a trava,
o que some, o que fica, a fila do Storage, a auditoria e o fluxo principal a partir do zero.

---

## 7. Sanitização periódica (o sistema não apaga nada sozinho)

A rotina antiga inativava candidatos após 2 meses sem evento e **apagava os dados pessoais** após 4 meses inativos, sozinha.
Isso acabou (parâmetros `retencao_meses_ate_*` removidos). No lugar: a cada ciclo (2 meses, configurável) o sistema gera uma
**lista de sugestões**, e o RH decide. Tela: **Sanitização**.

**Quem entra na lista** (candidatos `ativo` ou `inativo`; nunca `em_processo`, contratados nem quem o RH mandou manter):

| Critério | Regra (parâmetro em Configurações) | Pontos |
|---|---|---|
| Sem movimentação | Nada aconteceu (candidatura, currículo novo, contato, edição) há mais de N meses (`sanitizacao_meses_sem_movimentacao`, 6) | 2 |
| Reprovações | Reprovado em N vagas **diferentes** sem nenhuma aprovação (`sanitizacao_reprovacoes_max`, 3) | 2 |
| Baixa aderência | A melhor nota da IA às vagas ficou abaixo de N (`sanitizacao_aderencia_min`, 40) | 1 |
| Dados incompletos | A IA não classificou área/cargo/nível com a confiança mínima (`sanitizacao_confianca_min`, 50). Análise pendente não conta | 2 |
| Duplicidade | Outro cadastro do mesmo candidato — mesmo hash, ou mesmo telefone/e-mail **com nome parecido**. Só o mais antigo do par é sugerido (`sanitizacao_detectar_duplicidade`) | 3 |
| Prazo de armazenamento (LGPD) | Está no banco há mais de N meses sem consentimento registrado (`sanitizacao_retencao_maxima_meses`, 24) | 4 |

A soma define a **prioridade** (`sanitizacao_pesos` — JSON com os pontos de cada critério e os cortes): alta ≥ 4, média ≥ 2, senão baixa.
Os pesos, o intervalo e todos os limites são editáveis por administrador em Configurações; nada disso está fixo no código.

**Decisão do RH** (individual ou em lote — há o atalho "Selecionar todas de prioridade alta"), sempre com confirmação explícita:

- **Manter** — o candidato não volta a ser sugerido por N meses (padrão 6; `sanitizacao_adiar_meses`).
- **Inativar** — sai da lista de disponíveis; os dados continuam guardados; pode ser reativado.
- **Excluir definitivamente** — só administrador. Apaga nome, contatos, currículo, análises e os textos livres da IA e das entrevistas.
  Sobram o hash de identidade (para reconhecer um reenvio), as datas e as métricas. O arquivo do currículo sai do Storage na execução seguinte
  (fila `arquivos_para_remover`; se o Storage falhar, tenta de novo no dia seguinte).

**Auditoria:** cada decisão grava quem, quando, o quê e a observação (inclusive "manter"), na própria sugestão e em `logs_auditoria`
— sem dados pessoais nos registros.

**Aviso ao RH:** o selo no menu, a linha no Dashboard e a própria tela mostram as pendentes. Por e-mail (opcional): cadastre os destinatários em
Configurações → `sanitizacao_emails_aviso` e, se não usar a conta do IMAP, as variáveis `SMTP_*`. O e-mail traz **só contagens**, nunca dados de candidato.

**Permissões:** ver, manter e inativar = qualquer usuário ativo. Excluir definitivamente, gerar a lista fora do ciclo e editar parâmetros = administrador.

---

## 8. Permissões

O sistema tem dois perfis (`perfil_acesso`): `gerente_rh` e `administrador`. Um usuário inativo não vê nem grava nada (RLS).

| Ação | gerente_rh | administrador |
|---|:---:|:---:|
| Ver Banco de Talentos, candidatos, vagas, sanitização | ✔ | ✔ |
| Atribuir candidato a vaga, devolver ao banco, reprovar | ✔ | ✔ |
| Editar dados, registrar contato/consentimento, inativar/reativar | ✔ | ✔ |
| Pedir reanálise da IA | ✔ | ✔ |
| Sanitização: manter e inativar (individual ou em lote) | ✔ | ✔ |
| Sanitização: **excluir definitivamente**; gerar a lista agora | — | ✔ |
| Excluir dados de um candidato a pedido do titular (LGPD art. 18) | — | ✔ |
| Configurações (regras, modelos, pesos) | — | ✔ |

O painel **não escreve direto** em `candidatos`, `analises_ia` nem nas tabelas de sanitização: tudo passa por funções do banco
(`atribuir_candidato_vaga`, `encerrar_candidatura`, `editar_candidato`, `sanitizacao_decidir`…) que conferem quem chama.
Não existe perfil "somente leitura": criá-lo exigiria endurecer também as tabelas antigas (hoje todo usuário ativo grava nelas) — é uma decisão à parte.

---

## 9. Busca e índices

A tela filtra por nome, sexo, idade, cidade, área, cargo, nível e situação. Índices em `candidatos` (criados na `021`):

| Filtro | Índice | Por quê |
|---|---|---|
| Nome (busca **parcial**) | GIN trigrama em `nome_norm` (`pg_trgm`) | `LIKE '%x%'` só usa índice de trigrama. Full-text só casa palavra inteira, então não serve para "mar" → "Maria". `nome_norm` é o nome em minúsculas e sem acento (`norm_busca`), então acento e caixa não atrapalham |
| Sexo | btree parcial em `sexo` | Baixa cardinalidade; o ganho real vem dos índices compostos abaixo |
| Idade | btree em `nascimento_ref` | Idade é filtro por faixa de **data de nascimento**, não idade calculada linha a linha. Como a maioria dos currículos traz só a idade ("27 anos"), `nascimento_ref` = data exata, ou a estimada a partir da idade informada e do dia em que foi lida. A idade exibida é calculada na view, na hora |
| Cidade | btree `(cidade_norm text_pattern_ops, uf)` | Prefixo (`tagua%` acha "Taguatinga"), com ou sem estado |
| Cidade + área | btree `(cidade_norm text_pattern_ops, area_sugerida)` | A combinação mais usada da tela |
| Área / nível / situação | btree `(status_banco, area_sugerida, nivel_sugerido)` | Filtros mais frequentes |
| Cargo | btree parcial em `cargo_sugerido` | |
| Ordem da lista, fila de revisão manual, reanálise pendente, sanitização, duplicidade | índices parciais/de apoio | |

A sugestão atual da IA é **copiada** de `analises_ia` para `candidatos` (por gatilho) justamente para poder indexar e combinar (cidade + área)
sem juntar tabelas. Os filtros que dependem de **texto** (palavras no currículo, endereço, rotatividade) passam pela função
`filtrar_banco_talentos()`; escolaridade, experiência, CNH e idade são colunas com índice.

**Medido** (`sql/ensaio/20_teste_desempenho.sql`, 50 mil candidatos sintéticos): todas as buscas típicas em ≤ 25 ms; cada uma usa o índice previsto.
A sanitização completa (todas as regras) leva ~4,5 s para 50 mil candidatos e cresce de forma linear — com o volume real será instantânea.
O botão "Gerar sugestões agora" roda sob o timeout de 8 s da API do Supabase para usuários logados; o job diário não tem esse limite.

---

## 10. O que cada arquivo faz

| Arquivo | Responsabilidade |
|---|---|
| `main.py` | Entrada, argumentos de linha de comando |
| `api.py` | Servidor HTTP — análise imediata do upload manual e do botão "Reanalisar" (serviço à parte, opcional) |
| `pipeline.py` | Orquestra o fluxo: e-mail → Banco de Talentos → análise; reanálise; avaliação para vaga; upload manual |
| `sanitizacao.py` | Geração da lista de sugestões (job) e aviso por e-mail |
| `leitor_email.py` | IMAP: busca, lê e move mensagens |
| `extrator.py` | PDF, DOCX, OCR e Google Docs → texto |
| `ia.py` | Chamadas ao Claude (identificação, análise do candidato, avaliação para vaga, perfil de busca) |
| `database.py` | Acesso ao Supabase |
| `utils.py` | Telefone, hash de identidade, nascimento/idade, cidade/UF, limpeza de texto |
| `config.py` | Variáveis de ambiente e constantes |
| `sql/` | Migrações (`020`–`026`) e utilitários (`zerar_banco_talentos.sql` = recomeço limpo, seção 6.1); `sql/ensaio/` = ensaio em Postgres descartável |
| `tests/` | Testes do Python (sem rede) |

---

## 11. Decisões importantes

**Idempotência** — cada e-mail é registrado pelo `Message-ID` (no currículo). Rodar
duas vezes não gera duplicata.

**Nada é descartado em silêncio** — todo e-mail que não vira currículo entra na fila
de exceções, visível no sistema web.

**E-mail lido = e-mail que o sistema já leu** — todo e-mail processado é marcado como lido na caixa: currículo importado, exceção
registrada, reenvio ignorado, remetente bloqueado. Só o que falhou de vez (nem a exceção foi gravada) continua não lido e é tentado de
novo. (Antes só os e-mails de uma área — `SETOR_MARCAR_LIDO` — eram marcados; essa variável não existe mais e pode ser removida do
Railway.) O pipeline guarda um marcador de progresso (o último UID analisado) na tabela `configuracoes`, nas chaves `imap_ultimo_uid` e
`imap_uidvalidity`; apague essas duas linhas para recomeçar do e-mail não lido mais antigo. `--reler-caixa` (seção 6.1) é a exceção:
lê sem marcar nada.

**Reincidência: o mesmo currículo não é lido duas vezes** — seja qual for a vaga. O sistema reconhece o **arquivo** pela impressão digital
(`curriculos.arquivo_hash`, HMAC do conteúdo, sem custo de OCR nem de IA) e a **pessoa** por nome + telefone (ou e-mail + nome). Quem já está
no banco é **ignorado** — o e-mail é marcado como lido e o reenvio conta em "duplicados detectados". Só é lido de novo quando as **duas** coisas
são verdade: passaram **30 dias** da importação anterior (`REENVIO_DIAS_MINIMO`, em `config.py`) **e** o candidato foi **sanitizado** (inativo
ou com os dados excluídos). Nunca é relido quem está na **lista negra** ou tem retenção permanente (contratado). Consequência assumida: um currículo
**atualizado** dentro desse prazo não é lido. O RH ainda pode editar os dados do candidato à mão.
Se a análise da IA falhar, o candidato fica com o pedido de reanálise pendente e a próxima execução tenta de novo — o currículo nunca se perde.

**Lista negra de e-mails** — o RH bloqueia um endereço (tela "Lista negra") ou um candidato inteiro (botão no cadastro dele). O pipeline ignora
o remetente bloqueado e também o e-mail que aparecer **dentro** do currículo. Bloquear um candidato cancela as candidaturas abertas, inativa-o,
bloqueia todos os endereços ligados a ele e o mantém com retenção permanente (a sanitização não sugere apagá-lo: a lista existe para
reconhecê-lo se voltar). Ele só pode ser reativado depois de sair da lista negra. Excluir os dados continua possível e o bloqueio do e-mail fica.

**Descarte por vaga** — quem foi **reprovado ou descartado** numa vaga não pode ser atribuído de novo a ela (só a vagas novas: cada vaga tem
o seu id). "Devolver ao banco" (cancelar sem reprovar) não conta como descarte.

**Análise sugere, RH decide** — Área / Cargo / Nível são só apoio. Nunca atribuem candidato a vaga, e a tela avisa (sem bloquear) quando a área
sugerida não é o setor da vaga. A IA não considera idade, gênero, origem etc. na análise nem na avaliação (regra no prompt).

**Qualificação do currículo (setor, função e nível)** — a IA não recebe vaga: recebe o currículo e as listas de valores permitidos.
- **Prompt:** `SISTEMA_ANALISE` em `ia.py`, o texto do RH palavra por palavra (só os números da regra de rotatividade vêm de `config.py`).
  Ao mudar o texto, suba `VERSAO_PROMPT_ANALISE` (vai em `analises_ia.versao_prompt`).
- **Valores (o modelo real da empresa, 035):** setor = `setores`; cargo = `funcoes_setor` (cada cargo pertence a um setor; o mesmo nome, como
  "Auxiliar", existe em vários); nível = `niveis_funcao`: **Jovem Aprendiz, Trainee, Júnior, Pleno, Sênior** (`jovem_aprendiz`, `trainee`, `junior`,
  `pleno`, `senior`). Gerente, Encarregado e Supervisor são **cargos**, não níveis; "Estágio" é Trainee. **Jovem Aprendiz e Trainee só existem para 4
  cargos** (`funcoes_setor.aceita_iniciante`): Logística/Auxiliar, DP/Auxiliar, RH/Auxiliar e Loja/Repositor; nos demais só Júnior, Pleno e Sênior.
  O pipeline manda as listas (com a marca dos cargos que aceitam iniciante) junto com o currículo e, na volta, **descarta** qualquer valor que não
  esteja nelas: a função só vale dentro do setor escolhido, e Jovem Aprendiz/Trainee só nos 4 cargos (senão o nível fica vazio e o currículo vai para
  "revisão manual"). O formulário da vaga aplica a mesma regra (o banco também: gatilho `fn_vaga_valida_funcao`). As listas ficam 10 minutos na
  memória do processo.
- **Onde grava:** `curriculos.setor_adequado`, `funcao_setor`, `nivel_funcao` (o currículo analisado) e, com os mesmos valores,
  `analises_ia.area_sugerida` / `cargo_sugerido` / `nivel_sugerido`, de onde o gatilho copia para `candidatos` (é o que o painel lê).
  Currículo sem qualificação (os de antes da 031) fica com os três nulos até ser reanalisado.
- **Habilitar/desabilitar Jovem Aprendiz e Trainee (auditoria do critério):** o administrador faz em **Configurações → Níveis de experiência**, sem
  SQL (036). Cada nível mostra o critério que a IA lê (editável) e, nos dois iniciantes, o interruptor "Habilitado". **Desabilitado:** a IA deixa de
  receber o nível (e a marca "aceita …" e a regra deixam de citá-lo), o formulário da vaga deixa de oferecê-lo, o banco recusa uma vaga com ele, e uma
  resposta da IA com ele é descartada (o currículo vai para "revisão manual"). Currículos e vagas que já o têm **continuam como estão**. Júnior, Pleno
  e Sênior não desabilitam. Toda mudança (estado ou critério) fica em `logs_auditoria`, ação `alteracao_criterios`, com quem, quando, antes e depois.
  Ao mudar o critério ou o estado, currículos já qualificados não são requalificados sozinhos: use "Reanalisar" ou `--reanalisar`.
- **Manter as listas:** cargo novo = `insert into funcoes_setor (setor_id, nome, aceita_iniciante)`; para tirar um, `update … set ativo = false` (não
  apague se currículos ou vagas já o usam). Setor novo = linha em `setores`; setor que saiu do modelo = `ativo = false` (a IA e o formulário deixam de
  vê-lo; as vagas que apontam para ele continuam, marcadas "setor desativado"). Nível novo exige migração: o código também está nos `check` de
  `analises_ia`, `candidatos` e `niveis_funcao`. A carga da **035** é o documento "BRMODELO - SETORES E CARGOS" (13 setores, 51 cargos); a da 031 (palpite a
  partir do que a IA sugerira) foi substituída. O ajuste dos DADOS de produção (ordem dos setores, setores desativados, vagas e currículo afetados) está em
  `sql/catalogo_producao_2026-09.sql`, já executado. Currículo com par setor/cargo fora do modelo: zerar a qualificação e pedir reanálise (ver esse arquivo).
- **O que o prompt não devolve mais:** `confianca` e `palavras_chave` (o de antes devolvia). Sem confiança, o mínimo `ia_confianca_minima` só vale para
  análises antigas; a revisão manual passa a depender só de setor/função/nível classificados. Sem palavras-chave, a seleção por palavras-chave (029/030) deixou de existir:
  a vaga agora seleciona por setor + função + nível + nota (033, abaixo). `nota`, `requisitos_faltantes` e `eliminado_por_regra` são devolvidos mas não gravados (não há vaga).
- **Sanitização:** o critério "dados incompletos" contava confiança nula como 0 e passaria a sugerir todo candidato novo. A `031` recria
  `fn_sanitizacao_avaliar` (igual à da 023) para só contar a confiança quando ela existe.
- **Se as tabelas não existirem** (031 não aplicada) ou não houver nível ativo, a análise **não roda**: o candidato fica com o pedido de reanálise
  e a próxima execução tenta de novo. Falha ao gravar no currículo só entra no log: a análise já está salva.
- **Requalificar quem já está no banco:** `update candidatos set reanalise_solicitada_em = now() where status_banco <> 'expurgado'` e
  `python main.py --reanalisar` (uma chamada do modelo por candidato, cerca de US$ 0,012 cada).

**Seleção de CVs por vaga (sem IA)** — na tela de Vagas, o botão **"Selecionar CVs"** abre a janela de currículos já filtrada por SQL:
só os currículos **atuais** de candidatos disponíveis com **exatamente** o setor, a função e o nível da vaga (`selecionar_curriculos_vaga()`, 033),
do **maior para o menor** `curriculos.nota_classificacao` (a nota que a IA deu ao qualificar; sem nota vai por último). Fora da lista: quem não
está disponível, quem está na lista negra e quem já tem candidatura aberta, reprovada ou descartada **nesta** vaga. A janela também ordena por
"mais perto da loja" e limita por km (região, 030). Setor, função e nível da vaga são obrigatórios no formulário (a função só pode ser do setor
escolhido); vaga antiga sem eles mostra o aviso no card e o botão leva ao formulário. O "No banco" do card conta os mesmos currículos.

**Atribuir grava a qualificação da vaga (sem IA)** — quando o RH direciona um candidato a uma vaga, o banco (`fn_atribuir_candidato_vaga`, 034) grava o
setor, a função e o nível **da vaga** no currículo atual e nos campos que o painel lê (`candidatos.area/cargo/nivel_sugerido`), e tira a marca de
"revisão manual" (uma pessoa decidiu). A **nota não muda** (é a da IA). Só vale para vaga completa; vaga antiga sem função e nível não mexe em nada.
O que estava antes fica na auditoria (`logs_auditoria`, detalhe `qualificacao_gravada.anterior`) e a análise da IA, no histórico (`analises_ia`).
**Cancelar a seleção não desfaz isso**: o candidato volta ao Banco de Talentos com a qualificação que o currículo tinha no momento. Uma reanálise
pedida depois (botão "Reanalisar") grava a qualificação da IA por cima.

**Currículos selecionados de uma vaga** — na tela de Vagas, o **número de candidatos** do card (os que estão em processo nela) é clicável e abre a
tela **"Candidatos em processo" filtrada pela vaga**: a mesma tabela e as mesmas ações (ver o currículo, "Ver", "Agendar" a entrevista), em tela cheia,
com a coluna Vaga trocada por **Qualificação** (setor / cargo e nível) e a **Nota do CV**. Um banner no topo tem **"Selecionar CVs"** (a janela de seleção da
vaga) e **"Voltar às vagas"**; clicar em "Candidatos em processo" no menu volta a mostrar todas as vagas. **"Cancelar seleção"** em cada linha (usa
`encerrar_candidatura(..., 'cancelado')`) encerra a candidatura, cancela entrevista marcada e devolve o candidato ao banco, disponível de novo, inclusive
para esta mesma vaga, com a qualificação que o currículo já tem; a candidatura cancelada sai da tela e fica no histórico dele. As colunas novas vêm da
migração 037 (`vw_candidatos.vaga_id`, área/cargo/nível e `nota_curriculo`; `vw_candidaturas.nota_curriculo`). A "Nota do CV" é a `nota_classificacao` do
currículo (a antiga "Nota IA" era a da avaliação por vaga, que não existe mais); no detalhe da candidatura aparece como "Nota do currículo".

**Sem avaliação da IA na vaga** — atribuir um candidato grava a candidatura sem pedir avaliação (`avaliacao_pendente = false`) e a rotina diária não
avalia mais ninguém contra vaga. O código antigo (`ia.avaliar`, `SISTEMA_AVALIADOR`, `--reavaliar`, segunda opinião) continua no repositório, sem uso.

**Upload manual a partir de uma vaga** — o arquivo enviado pelo botão "Enviar currículo" com uma vaga escolhida entra no Banco de Talentos e
passa pelo MESMO processo dos e-mails (mesmo prompt de qualificação, mesmos dados extraídos), mas o **setor, a função e o nível do currículo são
os da vaga** (o RH já decidiu a compatibilidade); a nota é a da IA. O candidato é atribuído à vaga. Vaga antiga sem função e nível: a IA classifica o que faltar.
Sem vaga escolhida, é como um e-mail. Arquivo ilegível no upload não vai para a Fila de Exceção: o envio mostra o erro na lista "Últimos envios".

**Currículo por LINK (Google Docs/Drive)** — quando o candidato manda um link em vez de anexo, o texto é lido pelo link e o **arquivo também é baixado e
guardado no Storage** (Google Docs nativo vira PDF; PDF/DOCX enviado ao Drive é guardado como está), com nome, tipo, tamanho e impressão digital
como qualquer anexo. Sem isso o painel mostra "Arquivo original não disponível". Link privado ou com exportação bloqueada: o currículo entra
igual, sem o arquivo (o texto já foi lido). Para completar currículos por link que entraram antes desta correção, releia o e-mail pelo `Message-ID`
(`leitor_email.buscar_por_message_id`), ache o link com `utils.detectar_link_google_docs` e use `extrator.arquivo_do_google_docs`.

**Fila de Exceção × revisão manual** — só vai para a Fila de Exceção o e-mail que **não pôde ser lido** (anexo sem texto legível, formato inválido ou
pequeno demais, sem anexo nem link, link privado, não é currículo). "Pequeno demais" tem piso por tipo (`config.py`): **imagem** abaixo de 10 KB
(logotipo/ícone de assinatura) e **documento** abaixo de 500 bytes (vazio/truncado); um PDF simples de 3 KB é currículo válido. Com vários anexos vale o
primeiro que tiver texto legível. Currículo lido que a IA não conseguiu classificar entra no Banco de Talentos
com "revisão manual" e, sem setor, função e nível, não aparece na seleção de nenhuma vaga. Falha da própria IA (sem resposta) também não gera
exceção: o candidato espera a reanálise da próxima execução.

**Reprocessar uma exceção** — exige ter rodado `backend/sql/017_reprocessar_excecoes.sql`
uma vez no banco. Na Fila de exceções, o RH clica em "Reprocessar" quando acha que
o e-mail era um currículo de verdade (link do Drive que estava privado e já foi
corrigido, ou a IA errou o veredito). O painel só grava o pedido; a rotina diária
(ou `python main.py --reprocessar-excecoes`) busca o e-mail original de novo pelo
`Message-ID` e roda o mesmo caminho de sempre — extração, identificação, Banco de Talentos, análise.
Precisa do e-mail ainda estar na caixa (não vale para mensagens apagadas por outro
cliente) e do `Message-ID` ter sido salvo na exceção original (sempre é, exceto em
exceções muito antigas de antes desta função existir). Dando certo, a exceção some
da fila (fica "revisado", com uma nota); falhando de novo, o motivo do erro é
atualizado na mesma linha, sem duplicar. Mesma recomendação do `--reavaliar`: crie
um segundo serviço no Railway com esse comando e Cron Schedule mais frequente, se
quiser o resultado em minutos em vez de esperar a execução diária.

**Enviar currículo manualmente** — exige rodar `backend/sql/019_uploads_manuais.sql`
uma vez no banco (e a `021`, que torna a vaga opcional). No painel (Banco de Talentos ou Vagas → "Enviar currículo"), o RH sobe um arquivo
(PDF/DOC/DOCX) direto pro Storage — para currículo recebido fora do e-mail (WhatsApp, indicação, entrega em mão) — e a **vaga é opcional**.
O painel grava o pedido na fila (tabela `uploads_manuais`) e, se o serviço web estiver no ar (ver "Análise imediata" abaixo), chama a análise na
hora. Sem o serviço web, o currículo fica na fila normal: a rotina diária (ou `python main.py --uploads-manuais`) baixa o arquivo, extrai o
texto e o coloca no Banco de Talentos. Se o RH escolheu uma vaga, o candidato é atribuído a ela em nome dele (se já estiver em
processo ou a vaga tiver fechado, entra no banco mesmo assim e o aviso aparece em "Últimos envios"). Falhando (não é currículo, arquivo
ilegível), o motivo fica em `detalhe_erro`.

**Análise imediata (`backend/api.py`)** — um servidor HTTP pequeno (FastAPI) com duas rotas: `POST /uploads-manuais/{id}/avaliar` e
`POST /candidatos/{id}/analisar` (botão "Reanalisar"). Não tem segredo fixo: cada chamada leva o token de sessão do RH já logado no painel, e o
servidor confirma com o próprio Supabase Auth que a sessão é válida e o usuário está ativo (mesma regra da política `fn_usuario_ativo()`). Pra habilitar:

1. No Railway, **New Service** a partir do mesmo repositório (Root Directory `backend`,
   mesmas variáveis de ambiente do worker). Em **Settings → Deploy**, defina *Custom
   Start Command*: `uvicorn api:app --host 0.0.0.0 --port $PORT`. **Não** defina Cron
   Schedule neste serviço — ele precisa ficar sempre no ar, ao contrário do worker.
2. Em **Settings → Networking**, gere um domínio público. Anote a URL
   (ex.: `https://recrutei-api.up.railway.app`).
3. (Recomendado) Defina a variável `CORS_ORIGENS` com o domínio do painel publicado
   (ex.: `https://recrutei.vercel.app`) — vazio aceita qualquer origem, ok só para testar.
4. Em `frontend/js/nucleo.js`, preencha `API_URL` com a URL do passo 2 e publique o
   painel de novo (e libere essa URL em `connect-src` da CSP de `frontend/vercel.json`).

Sem isto tudo configurado, "Enviar currículo" e "Reanalisar" continuam funcionando do mesmo
jeito — só caem na fila normal (feitos na próxima execução da rotina), sem travar nem avisar erro.

**LGPD** — o prompt de análise e o de avaliação proíbem explicitamente considerar idade,
gênero, origem, religião ou qualquer característica protegida. Antes de
ir para a IA, e-mail, telefone e documentos (CPF, RG, CNH, CEP) são
trocados por marcadores, e o nome também é ocultado na análise e na avaliação. O hash
que detecta reenvios é um HMAC com chave secreta (`IDENTIDADE_CHAVE`),
não um SHA-256 simples, para que o expurgo não possa ser desfeito por
força bruta.

**O que mudou na retenção:** os candidatos agora ficam no banco até o RH decidir (seção 7), em vez de serem
inativados e expurgados automaticamente. Em contrapartida há o critério de **prazo máximo** (24 meses, configurável) e o registro de
consentimento (Editar dados → "Registrar que o candidato confirmou a permanência no banco"). O consentimento **não** é presumido ao receber o
currículo: sem registro, o prazo conta a partir da entrada. A exclusão a pedido do titular é do administrador ("Excluir dados" no candidato).
Como o candidato é reutilizado para várias vagas, **confirme com o jurídico** a base legal e o texto de consentimento antes de operar com um prazo
máximo maior. Fora do escopo desta entrega: coletar o consentimento **do próprio candidato** (formulário ou e-mail de confirmação).

**Custo** — cada execução registra tokens e custo estimado na tabela
`execucoes_pipeline`, visível no sistema. Por currículo novo: uma chamada Haiku (identificação), uma Haiku (perfil de busca) e uma Sonnet (análise).
Na vaga não há chamada à IA (a seleção é SQL); o assistente de rascunho de vaga é chamado só quando o RH clica em "Gerar rascunho".

**Modelos** — a identificação e a avaliação/análise podem usar Fable 5.1, Opus 5,
Sonnet 5 ou Haiku 4.5 (Configurações → Avaliação por IA, que mostra uma
estimativa em US$ a cada troca). Sonnet 5, Opus 5 e Fable 5.1 raciocinam
por padrão e o raciocínio é cobrado como saída: o Sonnet 5 roda com o
raciocínio desligado e o Opus 5/Fable 5.1 com esforço baixo (ver
`PARAMETROS_MODELO` em `config.py`). Ao acrescentar um modelo novo, inclua-o
em `PRECOS` (`config.py`) e em `MODELOS_IA` (`frontend/js/configuracoes.js`); modelo fora da
tabela funciona, mas o custo aparece como US$ 0,00. A análise usa o mesmo modelo de `modelo_ia_avaliacao`.

---

## 12. Testes

Três camadas, todas sem tocar no Supabase de produção:

```bash
# Python (Supabase e Claude simulados)
cd backend && .venv/bin/python -m unittest discover -s tests -v

# SQL: regras, sanitização, migração, índices e desempenho, num Postgres 17 descartável (precisa de Docker)
backend/sql/ensaio/ensaio.sh

# Painel + banco juntos: o frontend de verdade (jsdom) contra o Postgres migrado, via PostgREST (Docker + Node 20+)
backend/sql/ensaio/integracao/rodar.sh
```

O `ensaio.sh` monta uma **réplica mínima do schema de produção** (`sql/ensaio/00_base.sql` e `01_views_rls.sql`, lida do Supabase em 2026-09-23)
com **dados sintéticos** no mesmo perfil dos reais (100+ candidaturas, duplicatas, entrevistas, casos de borda), aplica `020`→`026`, roda os testes de
regras e de sanitização, reaplica (idempotência), instala em banco vazio, mede a busca com 50 mil candidatos e ensaia o script de zerar
(a trava; o que some e o que fica; a fila do Storage; a auditoria; o fluxo principal funcionando do zero; repetir é seguro). Não é o schema oficial:
se o de produção mudar, atualize a réplica. O `rodar.sh` roda, por cima disso, as consultas reais do painel (filtros, atribuição, devolução ao banco,
sanitização em lote, permissões/RLS) com o JWT de usuários do RH — e, depois, o mesmo painel contra o banco **zerado** (`banco_zerado.test.js`:
toda tela abre vazia, com a mensagem certa, sem erro de script e sem `NaN` na tela).

---

## 13. Limitações conhecidas

- **Google Docs privado**: só funciona se o candidato liberou o
  compartilhamento público. Caso contrário vai para exceções.
- **Arquivos `.doc` antigos** (Word 97-2003) podem falhar na extração.
- **Telefone com código de operadora** (`011 61 9...`) é ambíguo e pode ser
  normalizado incorretamente. Raro em currículos.
- **OCR** depende da qualidade da imagem. Fotos tortas ou de baixa
  resolução vão para exceções.
- **Um candidato, uma candidatura aberta**: para avaliar o mesmo candidato em duas vagas ao mesmo tempo é preciso encerrar uma antes.
  (Para permitir, remova o índice `uq_candidatura_aberta_por_candidato` e a checagem em `fn_atribuir_candidato_vaga`.)
- **Reconhecimento de reenvio**: sem telefone no currículo, só e-mail + nome iguais juntam os cadastros; senão surgem dois candidatos, e a
  sanitização sugere limpar o mais antigo (critério "duplicidade").
- A idade exibida quando o currículo só informa "N anos" é **estimada** (aparece com "~").
- O expurgo apaga os dados do **candidato**; e-mails de remetentes em `remetentes` e o corpo dos e-mails em `excecoes` não entram
  nele — o mesmo que já era antes.

---

## 14. Se algo der errado

| Sintoma | Causa provável |
|---|---|
| `Variável de ambiente obrigatória não definida` | Falta preencher o `.env` |
| IMAP falha ao conectar | Senha incorreta ou IMAP bloqueado no painel da Locaweb |
| Painel diz "Banco de Talentos ainda não foi habilitado" | Faltou rodar `sql/020` a `026` (seção 6) |
| Candidatos migrados sem Área/Cargo/Nível | Rode `python main.py --reanalisar` |
| Muitos candidatos em "revisão manual" | Currículos curtos/vagos, ou `ia_confianca_minima` alta demais (Configurações) |
| Pipeline erra com `column ... does not exist` / `candidatos` | Backend novo em banco antigo (ou o contrário): aplique as migrações e o deploy juntos |
| OCR nunca funciona | Tesseract não instalado |
| `row-level security` no log | Está usando a chave `anon` em vez da `service_role` |
| `--reler-caixa exige uma data inicial` | Passe `--desde AAAA-MM-DD` (ou defina `IMAP_DESDE`): sem data seria a caixa inteira |
| `--reler-caixa` leu só 10 e-mails | Não deveria: o `LIMITE_EMAILS` do `.env` não vale nesse comando. Confira se passou `--limite` |
| `--reler-caixa` parou no meio (timeout do IMAP) | Rode o mesmo comando de novo: o que já entrou é ignorado e o resto continua |
| Depois de zerar, arquivos antigos seguem no Storage | Rode `python main.py --manutencao` (ou espere a execução diária): ele esvazia `arquivos_para_remover` |
| Sanitização não gera lista | Ainda não venceu o intervalo (o log diz a data); use `python main.py --sanitizacao --forcar` ou o botão do administrador |
| E-mail de aviso não sai | Sem destinatário em Configurações, ou o SMTP recusou (o log mostra o motivo; a lista continua no painel) |
| Sugestão de sanitização sumiu | Sugestões de quem foi excluído ou entrou em processo são encerradas (`expirada`) — comportamento esperado |

Toda execução fica registrada em `execucoes_pipeline`, com erro e custo.
