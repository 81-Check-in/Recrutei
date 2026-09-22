# Recrutei — Histórico de commits

Relatório do que foi entregue em cada commit, do primeiro upload (17/09/2026) até a versão 1.7.2 (20/09/2026).
São 15 commits, todos de Miguel. Horários em UTC (Brasília = UTC−3).

**O que é o Recrutei.** Uma rotina diária lê a caixa de e-mail de vagas (IMAP), extrai o texto dos currículos
(PDF, DOCX, OCR e Google Docs), pede à IA (Claude) que classifique e avalie cada um contra as vagas abertas e
grava o resultado no Supabase. O RH acompanha tudo em um painel web: dashboard, vagas, triagem, candidatos,
entrevistas e configurações.

| Parte | Onde | Roda em |
|---|---|---|
| Rotina de e-mail + IA | [backend/](backend/) (Python) | Railway, por cron |
| Painel do RH | [frontend/index.html](frontend/index.html) (arquivo único) | Vercel (estático) |
| Banco e login | Supabase | — |

Instalação, variáveis de ambiente e deploy da rotina estão em [backend/README.md](backend/README.md).

---

## Resumo

| # | Commit | Data (UTC) | Versão | O que entrou |
|---|---|---|---|---|
| 1 | `074b427` | 17/09 13:22 | — | Painel web inicial |
| 2 | `fdc3512` | 18/09 19:14 | "versão 01" | Backend completo (e-mail → IA → Supabase) e ajustes no painel |
| 3 | `30633c8` | 18/09 19:53 | 1.1 | Leitor de e-mail nunca move nem apaga: só marca como lido |
| 4 | `9280f59` | 18/09 20:57 | 1.2 | Filtro por data de recebimento (`IMAP_DESDE`) |
| 5 | `6eb1938` | 18/09 21:27 | — | Painel movido para `frontend/` |
| 6 | `b65ea69` | 18/09 23:25 | 1.3 | Docker/Railway, "lido" só para um setor, exclusão de entrevista |
| 7 | `fa3ebba` | 18/09 23:51 | 1.4 | Remover candidato da lista |
| 8 | `67c9e2c` | 19/09 11:37 | 1.5 | Login como formulário |
| 9 | `ae7e5b0` | 19/09 11:41 | 1.5.1 | Mostrar/ocultar senha |
| 10 | `8a58c08` | 19/09 12:21 | 1.5.2 | Recuperação de senha completa |
| 11 | `ed8a1bb` | 19/09 14:43 | 1.6 | Redesenho visual e acessibilidade |
| 12 | `26409d0` | 19/09 15:11 | 1.7 | Trocar a vaga do candidato e reavaliar |
| 13 | `42777b9` | 20/09 02:28 | 1.7.1 | Rotatividade, perfil de busca e filtros avançados (backend e banco) |
| 14 | `67086bb` | 20/09 17:06 | "17.1" | Modo escuro |
| 15 | `c8b1d1c` | 20/09 21:55 | 1.7.2 | Endurecimento de segurança e animações de troca de tela |

---

## Detalhe por commit

### 1. `074b427` — Add files via upload (17/09)
- Entra o `recrutei.html` (2.083 linhas): painel em arquivo único, ligado ao Supabase.
- Telas: login, dashboard, vagas, triagem de currículos, candidatos, entrevistas (calendário, agendamento com
  mensagem pronta no WhatsApp e registro do resultado) e configurações.

### 2. `fdc3512` — versão 01 do sistema (18/09)
16 arquivos, +2.222 / −21.

**Backend (novo)**
- `leitor_email.py` (IMAP), `extrator.py` (PDF, DOCX, OCR com Tesseract, Google Docs, com limites de tempo e de
  tamanho), `ia.py`, `pipeline.py`, `database.py`, `utils.py`, `config.py` e `main.py`
  (`--testar`, `--simular`, `--limite`, `--manutencao`).
- IA em duas etapas: um modelo barato classifica (é currículo? qual vaga?) e outro avalia (nota 0–100, pontos
  fortes, lacunas, requisitos faltantes). Nota entre 60 e 75 recebe segunda avaliação; divergência acima de 10
  pontos vai para revisão humana. Faltou requisito obrigatório: nota limitada a 45.
- Regras de negócio: idempotência por `Message-ID`; tudo que não vira candidatura entra na fila de exceções;
  custo e tokens de cada execução gravados em `execucoes_pipeline`.
- LGPD: contatos e documentos são mascarados antes de ir à IA; o hash de reenvio é HMAC com chave secreta
  (`IDENTIDADE_CHAVE`); inativação e expurgo automáticos dos dados pessoais (prazos configuráveis).
- Deploy inicial: `Procfile`, `nixpacks.toml`, `runtime.txt`, `requirements.txt`, `.env.example`, `.gitignore`
  e o README do backend.

**Painel (+217 linhas)**
- Vagas: opção "TODAS" nas lojas e ordem fixa de exibição (CFS, CFR, CFVP…).
- Configurações: seletor de modelo de IA (Fable 5.1, Opus 5, Sonnet 5, Haiku 4.5) com estimativa de custo em US$
  por currículo; interruptor da segunda avaliação.
- Segurança: iniciais do nome só com letras e dados passados por `data-*` em vez de texto dentro de `onclick`
  (evita injeção de HTML).
- Modais deixam de fechar ao clicar fora, para não perder o que foi digitado.

### 3. `30633c8` — Versão 1.1 (18/09)
- O leitor de e-mail **não move, não copia e não apaga** mais nada; a única alteração na caixa é marcar como lido.
- Removidos `IMAP_PASTA_PROCESSADOS`, a criação de pasta e o `conn.close()` (o `CLOSE` do IMAP apaga em definitivo
  mensagens marcadas `\Deleted`). A caixa é aberta em modo somente leitura na busca.
- `mover_para_processados` virou `marcar_como_lidas`. O campo saiu da tela de Configurações.

### 4. `9280f59` — Versão 1.2 (18/09)
- Nova variável `IMAP_DESDE` (AAAA-MM-DD): só processa não lidos recebidos a partir da data. Serve para não
  reprocessar um acúmulo antigo. Valida o formato ao iniciar e está documentada no README.
- `supabase` 2.10.0 → 2.31.0.
- `recrutei.html` renomeado para `index.html`.

### 5. `6eb1938` — Move painel para frontend/index.html (18/09)
- Só move o arquivo, separando o repositório em `backend/` e `frontend/`.

### 6. `b65ea69` — Versão 1.3 (18/09)
11 arquivos, +384 / −61.

**Deploy**
- `Dockerfile` (Python 3.11, Tesseract em português, Poppler) e `.dockerignore`. O README passa a descrever o
  deploy no Railway: Root Directory `backend`, cron `0 8 * * *` (05h em Brasília).

**Leitura de e-mail**
- `SETOR_MARCAR_LIDO` (padrão: Logística): só e-mails classificados nesse setor viram "lidos". Os demais
  continuam não lidos na caixa, mas são analisados e registrados do mesmo jeito.
- Marcador de progresso (`imap_ultimo_uid` e `imap_uidvalidity`, na tabela `configuracoes`) para não reler os
  que ficaram não lidos. Detecta caixa reindexada e só avança até onde tudo foi tratado sem falha.
- Falha ao criar a candidatura agora vai para a fila de exceções (antes só aparecia no log).

**Banco (SQL)**
- Gatilho: uma candidatura não pode ter duas entrevistas ativas; índice único: uma entrevista só é remarcada
  uma vez.
- Função `excluir_entrevista` (RPC). Regras: só quem agendou ou um administrador; só entrevista ainda
  "agendada"; se era a única ativa, o candidato volta para "selecionado".

**Painel**
- Botão de excluir entrevista agendada por engano, com confirmação.
- Agendar ficou à prova de duplo clique, confere se já há entrevista ativa e trata o erro de remarcação
  duplicada (`23505`).

### 7. `fa3ebba` — Versão 1.4 (18/09)
- Candidatos: botão de remover da lista. A candidatura vira `descartado` com data, autor e motivo, e o currículo
  permanece no histórico. Se a política de acesso (RLS) barrar, o painel avisa "sem permissão" em vez de fingir
  sucesso. Novo selo "Descartado".
- Os dois scripts SQL da 1.3 saíram do repositório. O painel continua usando `excluir_entrevista`, que foi
  redefinida na migração 015 (commit 15).

### 8. `67c9e2c` — Versão 1.5 (19/09)
- Login vira `<form>`: Enter envia e gerenciadores de senha funcionam.
- O campo aceitava só o nome de usuário e completava com `@recrutei.com.br` (revertido no commit 10).

### 9. `ae7e5b0` — Versão 1.5.1 (19/09)
- Botão de olho para mostrar/ocultar a senha, com rótulos de acessibilidade. A senha volta a ficar oculta ao sair.

### 10. `8a58c08` — Versão 1.5.2 (19/09)
- Login volta a pedir o e-mail completo (removido o domínio automático).
- **Recuperação de senha completa.** O link do e-mail volta ao painel e abre o modal "Definir nova senha"
  (mínimo de 8 caracteres, com confirmação). Cobre link inválido ou expirado; cancelar encerra a sessão aberta
  pelo link; `Esc` não fecha esse modal. A resposta não revela se o e-mail existe. Erros do Supabase Auth
  traduzidos.
- Requer que a URL do painel esteja em Supabase → Authentication → URL Configuration → Redirect URLs.

### 11. `ed8a1bb` — Versão 1.6 (19/09)
Só frontend, +277 / −14.
- Visual: menu lateral grafite e recolhível (a preferência fica salva no navegador), nova marca em SVG e favicon,
  login em "vidro escuro", cards do dashboard translúcidos.
- Responsivo: ajustes em 900, 600, 520 e 390 px.
- Acessibilidade: itens do menu viram `<button>` com `aria-current`, foco visível, menu mobile inerte quando
  fechado e respeito a `prefers-reduced-motion`.

### 12. `26409d0` — Versão 1.7 (19/09)
**Trocar a vaga do candidato e reavaliar.**
- Painel: na análise do candidato, a seção "Vaga avaliada" permite escolher outra vaga e clicar em Reavaliar.
  Enquanto pendente, a triagem mostra "…" e "Avaliação pendente" no lugar da nota antiga, e o botão de chamar
  para entrevista fica oculto. Selo "Vaga definida pelo RH".
- Backend: novo comando `python main.py --reavaliar`; a rotina diária também reavalia os pendentes antes dos
  e-mails novos. Usa o texto já guardado, sem reler o e-mail. A nota nova entra como a mais recente e as
  anteriores ficam em `avaliacoes`.
- Casos de borda: vaga que não está mais aberta ou currículo expurgado mantêm a nota anterior; falha da IA deixa
  em análise para a próxima execução. Sem nada pendente, não chama a IA nem registra execução.
- Para a nota sair em minutos e não no dia seguinte, o README sugere um segundo serviço no Railway com
  `python main.py --reavaliar` e cron `*/15 * * * *`.

### 13. `42777b9` — Versão 1.7.1 (20/09)
Só backend e banco; **não mexe no painel**. 7 arquivos, +375 / −5.
- **Rotatividade** avaliada em todo currículo: uma frase no resumo, mais a etiqueta "Alta rotatividade" (em
  lacunas) ou "Baixa rotatividade" (em pontos fortes). Não altera a nota. Os limites estão em `config.py`
  (`ROT_*`): alta = 3 ou mais empregos com menos de 12 meses, ou 3 ou mais empresas em 12 meses; baixa =
  permanência média de 24 meses ou mais, sem empregos curtos. Estágio, aprendiz, temporário, sazonal e obra
  não contam.
- **Perfil de busca:** idade lida do texto localmente (a data de nascimento não vai à IA); escolaridade, anos de
  experiência e CNH extraídos pelo modelo de classificação. Ficam em `dados_pessoais`.
- Novo `python main.py --enriquecer [--limite N]`: preenche o perfil dos currículos que chegaram antes desta
  versão.
- `backend/sql/filtros_avancados.sql`: funções `norm_busca` (busca sem acento) e `filtrar_triagem(jsonb)`, com
  filtros por palavras-chave (todas/qualquer; no currículo, na análise ou nos dois), localização (incluir e
  excluir), idade, escolaridade mínima, experiência mínima, CNH e rotatividade. Executáveis só por usuário logado.
  Rodar uma vez no SQL Editor do Supabase.

### 14. `67086bb` — "Versão 17.1" (20/09)
Só frontend, +200 / −58. **Modo escuro.**
- Botão de tema na barra superior. Sem escolha salva, segue o tema do sistema em tempo real.
- O tema é aplicado antes da primeira pintura, para não piscar o claro.
- Cores fixas do CSS trocadas por variáveis (`--surface`, `--text`, `--gray-border`…), com paleta escura para
  conteúdo, drawer, modais, tabelas, botões, notas e toasts.
- Nome do commit fora do padrão (ver pontos de atenção).

### 15. `c8b1d1c` — Versão 1.7.2 (20/09)
**Correções da auditoria de segurança de 20/09/2026.**

Migração `015_endurecimento_acessos.sql` — brechas encontradas:
1. O cadastro público estava aberto e o gatilho de perfil lia o campo `perfil` de `raw_user_meta_data` (que o
   próprio cliente preenche): qualquer pessoa podia criar uma conta **administrador ativa**.
2. Qualquer usuário podia editar a própria linha inteira em `usuarios`, inclusive `perfil` e `ativo`.
3. `fn_excluir_dados_candidato` (expurgo LGPD), sem checagem de quem chama, era executável por RPC.
4. Privilégios de tabela em excesso (`anon` com acesso total; `TRUNCATE`, `TRIGGER` e `REFERENCES` para
   `authenticated`).

Correções: perfil só vem de `raw_app_meta_data` e **todo usuário novo nasce inativo**; o usuário só atualiza o
próprio `ultimo_acesso`; funções internas deixam de ser chamáveis por RPC; `excluir_entrevista` passa a exigir
usuário ativo; privilégios revogados.

Migração `016_delete_somente_admin.sql`: o `DELETE` direto pela API passa a ser só do administrador (antes,
qualquer usuário ativo apagava candidaturas, currículos e avaliações), inclusive no armazenamento dos arquivos.
`requisitos` e `vaga_empresas` ficaram de fora porque o painel apaga e recria essas linhas ao salvar uma vaga.
O cabeçalho informa que foi aplicada em 20/09, após ensaio em transação desfeita (22 verificações).

`verificar_seguranca.sql`: consulta só de leitura; depois da 015 todas as linhas devem dar `false`.

Frontend:
- `frontend/vercel.json`: cabeçalhos de segurança (CSP, `X-Frame-Options: DENY`, `nosniff`, `Referrer-Policy`,
  `Permissions-Policy`).
- Bibliotecas do CDN com versão fixa e SRI (`integrity`); o ícone `@latest` passou a `2.47.0`.
- Animação de troca de tela e "pílula de vidro" que desliza sob o item ativo do menu e das abas.

---

## Pontos de atenção

1. **Novos usuários nascem inativos (1.7.2).** Depois de criar o usuário em Supabase → Authentication → Users,
   ative-o: `update public.usuarios set ativo = true where email = '...';`. Para nascer administrador, defina
   `perfil` em `app_metadata` (não em `user_metadata`) ou promova por SQL. Gerente de RH não apaga mais registros.
2. **Conferir se a 015 foi aplicada.** O arquivo da 016 diz que foi aplicada; o da 015 não diz. Rode
   `verificar_seguranca.sql`: todas as linhas devem dar `false`.
3. **Filtros avançados sem tela.** O banco e a IA estão prontos desde a 1.7.1, mas não há no repositório nenhum
   uso de `filtrar_triagem` no painel: a Triagem só tem busca por nome e os filtros de vaga, nota e status.
   Falta a interface (ou ela não foi commitada).
4. **`--enriquecer` não está no `backend/README.md`.** Currículos anteriores à 1.7.1 só ganham idade,
   escolaridade, experiência e CNH depois de rodar esse comando uma vez.
5. **Referência quebrada no painel.** A mensagem de erro de exclusão de entrevista manda rodar
   `backend/sql/excluir_entrevista.sql`, arquivo removido na 1.4. Hoje a função só existe na migração 015.
6. **Nome de commit fora do padrão.** O `67086bb` se chama "Versão 17.1", mas é o modo escuro entre a 1.7.1 e a
   1.7.2. Ao buscar no histórico, procure por ele como "modo escuro".
7. **Arquivos de deploy possivelmente obsoletos.** `Procfile`, `nixpacks.toml` e `runtime.txt` vêm da versão 01;
   desde a 1.3 o deploy descrito no README usa o `Dockerfile`. Confirme e remova se não forem mais usados.
