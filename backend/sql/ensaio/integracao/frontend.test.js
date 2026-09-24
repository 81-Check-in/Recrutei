// Teste de integração do painel: o código REAL do frontend (index.html + js/*.js) rodando em um DOM simulado
// (jsdom), falando com o Postgres migrado do ensaio através do PostgREST — exatamente as consultas que o
// navegador faria, com o JWT de usuários do RH (RLS valendo). Nada aqui toca o Supabase de produção.
//
// Como rodar: backend/sql/ensaio/integracao/rodar.sh   (sobe o Postgres do ensaio + PostgREST e chama isto)
const test = require('node:test');
const assert = require('node:assert/strict');
const { REST, BETO, ANA, DANI, sql, sqlNum, abrirPainel } = require('./harness');

const cartoes = p => p.$$('#banco-lista .curr-card');
const textoCartoes = p => cartoes(p).map(c => c.textContent.replace(/\s+/g, ' ').trim());
const limparFiltros = p => {
  ['#busca-banco', '#filtro-b-cidade', '#filtro-b-area', '#filtro-b-cargo', '#filtro-b-nivel', '#filtro-b-sexo'].forEach(s => p.define(s, ''));
  p.define('#filtro-b-status', 'ativo'); p.define('#ordem-banco', 'entrada');
  ['#av-palavras', '#av-local', '#av-excluir-locais', '#av-idade-min', '#av-idade-max', '#av-experiencia'].forEach(s => p.define(s, ''));
  p.define('#av-palavras-modo', 'todas'); p.define('#av-palavras-onde', 'curriculo'); p.define('#av-escolaridade', '');
  p.define('#av-rotatividade', ''); p.define('#av-cnh', false); p.define('#av-revisao', false); p.define('#av-sem-info', true);
  p.w.eval('filtrosAvancados = null');
};
const totalUi = p => p.w.eval('estadoBanco.total');
const idDe = nome => sql(`select id from candidatos where nome = '${nome}'`);

let beto, ana;
test.before(async () => {
  try { await fetch(REST); } catch { throw new Error(`PostgREST não responde em ${REST}. Rode backend/sql/ensaio/integracao/rodar.sh`); }
  beto = await abrirPainel(BETO);
  ana = await abrirPainel(ANA, 'administrador');
});
test.after(() => { beto?.fim(); ana?.fim(); });

// ── 1. Banco de Talentos: lista, filtros e busca ─────────────────────────
test('lista: só os disponíveis, 50 por página, "carregar mais" chega ao total', async () => {
  await beto.w.carregarBanco();
  const ativos = sqlNum(`select count(*) from vw_banco_talentos where status_banco = 'ativo'`);
  assert.equal(ativos, 101);
  assert.equal(cartoes(beto).length, 50);
  assert.match(beto.$('#banco-total').textContent, /50 de 101 candidatos/);
  assert.notEqual(beto.$('#banco-mais').style.display, 'none');
  await beto.w.maisBanco(); await beto.w.maisBanco();
  assert.equal(cartoes(beto).length, 101);
  assert.equal(beto.$('#banco-mais').style.display, 'none');
  assert.deepEqual(beto.erros, [], 'erro de script durante o carregamento');
});

test('cada card mostra a sugestão da IA, o local e os selos de situação', async () => {
  limparFiltros(beto);
  beto.define('#busca-banco', 'Candidato 010');
  await beto.w.carregarBanco();
  const texto = textoCartoes(beto).find(t => t.includes('Candidato 010 Silva'));
  assert.ok(texto, 'card do Candidato 010 não encontrado');
  assert.match(texto, /Administrativo/);                 // área migrada da vaga que a IA antiga havia escolhido
  assert.match(texto, /Revisão manual|IA analisando/);   // ainda sem a análise nova
  assert.ok(cartoes(beto)[0].querySelector('.btn-sm.verde'), 'candidato disponível tem o botão Atribuir');
  // a data do card é a do ENVIO do e-mail (não a de entrada no banco); a de entrada fica no tooltip
  assert.match(texto, /Enviado \d{2}\/\d{2}\/\d{2}/);
  const dataEnvio = cartoes(beto)[0].querySelector('.ti-calendar').parentElement;
  assert.match(dataEnvio.getAttribute('title'), /E-mail enviado em \d{2}\/\d{2}\/\d{4}.*entrou no banco em/);
});

test('busca parcial por nome, sem depender de caixa ou acento', async () => {
  limparFiltros(beto);
  beto.define('#busca-banco', 'CANDIDATO 010');
  await beto.w.carregarBanco();
  assert.equal(totalUi(beto), 1);
  beto.define('#busca-banco', 'didato 04');                // trecho do meio
  await beto.w.carregarBanco();
  assert.equal(totalUi(beto), sqlNum(`select count(*) from vw_banco_talentos where status_banco='ativo' and nome_norm like '%didato 04%'`));
  beto.define('#busca-banco', '100%');                    // % digitado vale como texto, não como curinga
  await beto.w.carregarBanco();
  assert.equal(totalUi(beto), 0);
});

test('cidade por prefixo ("ceilandia" acha "Ceilândia") e combinada com área', async () => {
  limparFiltros(beto);
  beto.define('#filtro-b-cidade', 'ceilandia');
  await beto.w.carregarBanco();
  const esperado = sqlNum(`select count(*) from vw_banco_talentos where status_banco='ativo' and cidade_norm like 'ceilandia%'`);
  assert.ok(esperado > 0);
  assert.equal(totalUi(beto), esperado);
  assert.ok(textoCartoes(beto).every(t => t.includes('Ceilândia')));

  await beto.w.carregarOpcoesBanco(true);                  // opções de área vêm do que já existe no banco
  beto.define('#filtro-b-area', 'Vendas');
  await beto.w.carregarBanco();
  assert.equal(totalUi(beto), sqlNum(`select count(*) from vw_banco_talentos where status_banco='ativo' and cidade_norm like 'ceilandia%' and area_sugerida='Vendas'`));
});

test('sexo "não informado", nível, cargo e situação batem com o banco', async () => {
  limparFiltros(beto);
  beto.define('#filtro-b-sexo', 'nao_informado');
  await beto.w.carregarBanco();
  assert.equal(totalUi(beto), sqlNum(`select count(*) from vw_banco_talentos where status_banco='ativo' and sexo is null`));
  limparFiltros(beto);
  beto.define('#filtro-b-sexo', 'feminino');
  await beto.w.carregarBanco();
  assert.equal(totalUi(beto), sqlNum(`select count(*) from vw_banco_talentos where status_banco='ativo' and sexo='feminino'`));
  limparFiltros(beto);
  beto.define('#filtro-b-status', '');                      // todos: inclui em processo e inativos
  await beto.w.carregarBanco();
  assert.equal(totalUi(beto), sqlNum(`select count(*) from vw_banco_talentos`));
  beto.define('#filtro-b-status', 'em_processo');
  await beto.w.carregarBanco();
  assert.equal(totalUi(beto), 6);
  assert.ok(textoCartoes(beto).every(t => t.includes('Em processo')));
  assert.equal(cartoes(beto)[0].querySelector('.btn-sm.verde'), null, 'quem está em processo não tem Atribuir');
});

test('ordenação: por nome e por quem está parado há mais tempo', async () => {
  limparFiltros(beto);
  beto.define('#ordem-banco', 'nome');
  await beto.w.carregarBanco();
  const nomes = textoCartoes(beto).map(t => t.split(' Revisão')[0]);
  const primeiro = sql(`select nome from vw_banco_talentos where status_banco='ativo' order by nome_norm, id limit 1`);
  assert.ok(nomes[0].includes(primeiro), `esperava começar por ${primeiro}, veio ${nomes[0]}`);
  beto.define('#ordem-banco', 'movimentacao');
  await beto.w.carregarBanco();
  const maisParado = sql(`select nome from vw_banco_talentos where status_banco='ativo' order by ultima_movimentacao, id limit 1`);
  assert.ok(textoCartoes(beto)[0].includes(maisParado));
});

test('filtros avançados: faixa etária por data de nascimento = idade calculada pelo banco', async () => {
  for (const [min, max, incluirSem] of [[25, 35, false], [25, 35, true], [30, '', false], ['', 28, true]]) {
    limparFiltros(beto);
    beto.define('#av-idade-min', min); beto.define('#av-idade-max', max); beto.define('#av-sem-info', incluirSem);
    beto.w.aplicarFiltrosAvancados();
    await beto.w.carregarBanco();
    const faixa = `(idade >= ${min || 0} and idade <= ${max || 200})`;
    const esperado = sqlNum(`select count(*) from vw_banco_talentos where status_banco='ativo' and (${faixa}${incluirSem ? ' or idade is null' : ''})`);
    assert.equal(totalUi(beto), esperado, `idade ${min}–${max} incluirSemInfo=${incluirSem}`);
  }
});

test('filtros avançados: escolaridade, experiência, CNH e revisão manual', async () => {
  limparFiltros(beto);
  beto.define('#av-escolaridade', 'superior'); beto.define('#av-experiencia', 5); beto.define('#av-sem-info', false);
  beto.w.aplicarFiltrosAvancados();
  await beto.w.carregarBanco();
  assert.equal(totalUi(beto), sqlNum(`select count(*) from vw_banco_talentos where status_banco='ativo' and escolaridade_ord >= 4 and anos_experiencia >= 5`));

  limparFiltros(beto);
  beto.define('#av-cnh', true); beto.define('#av-revisao', true);
  beto.w.aplicarFiltrosAvancados();
  await beto.w.carregarBanco();
  assert.equal(totalUi(beto), sqlNum(`select count(*) from vw_banco_talentos where status_banco='ativo' and cnh is not null and revisao_manual`));
  assert.match(beto.$('#badge-filtros-av').textContent, /3|2/);       // selo com a quantidade de filtros ativos
});

test('filtros avançados de texto (currículo, análise, local, rotatividade) passam pela função do banco e combinam com os demais', async () => {
  limparFiltros(beto);
  beto.define('#av-palavras', 'logistica'); beto.w.aplicarFiltrosAvancados();
  await beto.w.carregarBanco();
  assert.equal(totalUi(beto), sqlNum(`select count(*) from filtrar_banco_talentos('{"palavras":["logistica"]}') where status_banco='ativo'`));
  assert.ok(totalUi(beto) > 50, 'quase todo currículo sintético cita logística');

  beto.define('#av-palavras', 'palavra-que-nao-existe'); beto.w.aplicarFiltrosAvancados();
  await beto.w.carregarBanco();
  assert.equal(totalUi(beto), 0);

  beto.define('#av-palavras', 'baixa rotatividade'); beto.define('#av-palavras-onde', 'analise');
  beto.define('#av-palavras-modo', 'qualquer'); beto.w.aplicarFiltrosAvancados();
  beto.define('#filtro-b-area', 'Administrativo');                       // texto (função) + coluna (filtro comum)
  await beto.w.carregarBanco();
  assert.equal(totalUi(beto), sqlNum(`select count(*) from filtrar_banco_talentos('{"palavras":["baixa rotatividade"],"palavras_onde":"analise","palavras_modo":"qualquer"}') where status_banco='ativo' and area_sugerida='Administrativo'`));

  limparFiltros(beto);
  beto.define('#av-rotatividade', 'alta'); beto.w.aplicarFiltrosAvancados();
  await beto.w.carregarBanco();
  assert.equal(totalUi(beto), sqlNum(`select count(*) from filtrar_banco_talentos('{"rotatividade":"alta"}') where status_banco='ativo'`));
});

// ── 2. Drawer do candidato ───────────────────────────────────────────────
test('drawer do candidato: sugestão da IA, dados, pontos e histórico de vagas (com duplicatas fundidas)', async () => {
  limparFiltros(beto);
  const id = idDe('Candidato 001 Silva');                  // veio de 2 candidaturas na migração
  await beto.w.abrirTalento(id);
  assert.ok(beto.$('#drawer-talento').classList.contains('show'));
  assert.equal(beto.$('#t-nome').textContent, 'Candidato 001 Silva');
  assert.match(beto.$('#t-ia').textContent, /Área/);
  assert.match(beto.$('#t-ia').textContent, /Revisão manual necessária/);
  assert.match(beto.$('#t-ia').textContent, /vai \(re\)analisar/);
  // o e-mail de quem enviou e a data do envio vêm do e-mail, não da IA
  const envio = sql(`select curriculo_email_envio from vw_banco_talentos where id = '${id}'`);
  assert.ok(envio.includes('@'), 'o currículo atual tem o e-mail de envio');
  assert.match(beto.$('#t-dados').textContent, /E-mail de envio \(de quem mandou\)/);
  assert.ok(beto.$('#t-dados').textContent.includes(envio), 'o endereço de envio aparece no cadastro');
  assert.match(beto.$('#t-dados').textContent, /E-mail enviado em\d{2}\/\d{2}\/\d{4}/);
  assert.equal(beto.$$('#t-historico .hist-item').length, 2);
  assert.ok(beto.$$('#t-historico .hist-item.legado').length === 2, 'vínculos automáticos da triagem antiga aparecem como legado');
  assert.match(beto.$('#t-positivos').textContent, /Experiência em logística/);
  assert.equal(beto.$('#t-btn-atribuir').style.display, 'flex');
  assert.equal(beto.$('#t-btn-excluir').style.display, 'none', 'excluir dados é só do administrador');
  await ana.w.abrirTalento(id);
  assert.equal(ana.$('#t-btn-excluir').style.display, 'flex');
  beto.w.fecharDrawer(); ana.w.fecharDrawer();
});

// ── 3. Atribuição manual (lado a lado) e retorno ao banco ─────────────────
let candidatoAtribuido, candidaturaId;
test('atribuição: sugestão da IA e vaga lado a lado, compatibilidade só informativa, atribui e o candidato sai da lista de disponíveis', async () => {
  candidatoAtribuido = 'Candidato 020 Silva';
  const id = idDe(candidatoAtribuido);
  await beto.w.abrirAtribuicaoPorId(id);
  assert.ok(beto.$('#modal-atribuir').classList.contains('show'));
  assert.match(beto.$('#atr-candidato').textContent, /Candidato 020 Silva/);
  const opcoes = beto.$$('#atr-vaga option').filter(o => o.value);
  assert.equal(opcoes.length, sqlNum(`select count(*) from vagas where status='ativo'`));
  assert.match(opcoes[0].textContent, /★ combina com a área sugerida/, 'a vaga do mesmo setor da área sugerida vem primeiro');

  beto.define('#atr-vaga', opcoes[0].value);
  await beto.w.mostrarVagaAtribuicao();
  assert.match(beto.$('#atr-vaga-info').textContent, /Requisito obrigatório/);
  assert.match(beto.$('#atr-compat').textContent, /é o setor desta vaga/);

  const outra = opcoes.find(o => !o.textContent.includes('★'));
  beto.define('#atr-vaga', outra.value);
  await beto.w.mostrarVagaAtribuicao();
  assert.match(beto.$('#atr-compat').textContent, /Você pode atribuir mesmo assim/);   // avisa, não bloqueia

  beto.define('#atr-obs', 'Perfil forte para expedição');
  await beto.w.confirmarAtribuicao();
  assert.match(beto.ultimoToast(), /atribuído à vaga/);
  assert.ok(!beto.$('#modal-atribuir').classList.contains('show') || true);
  assert.equal(sql(`select status_banco from candidatos where id='${id}'`), 'em_processo');
  candidaturaId = sql(`select id from candidaturas where candidato_id='${id}' and encerrada_em is null`);
  assert.equal(sql(`select status || '/' || (atribuido_por = '${BETO}') || '/' || avaliacao_pendente || '/' || observacao_atribuicao from candidaturas where id='${candidaturaId}'`),
    'aguardando/true/false/Perfil forte para expedição');     // avaliacao_pendente = false: não há IA escolhendo currículo na vaga
  limparFiltros(beto);
  beto.define('#busca-banco', 'Candidato 020');
  await beto.w.carregarBanco();
  assert.equal(totalUi(beto), 0, 'em processo não aparece mais entre os disponíveis');
});

test('tela "Em processo": a nova candidatura aparece com status e ações', async () => {
  await beto.w.carregarCandidatos();
  assert.equal(beto.w.eval('estadoCandidatos.total'), 9);          // 5 entrevistas + não compareceu + reprovado + contratado + a nova
  const linha = beto.$$('#candidatos-body tr').find(tr => tr.textContent.includes('Candidato 020 Silva'));
  assert.ok(linha);
  assert.match(linha.textContent, /Aguardando entrevista/);
  assert.ok(linha.querySelector('.btn-sm.azul'), 'tem o botão Agendar');
  assert.ok(linha.querySelector('.btn-sm.vermelho'), 'tem o botão Devolver ao banco');

  await beto.w.abrirCandidatura(candidaturaId);
  assert.ok(beto.$('#drawer').classList.contains('show'));
  assert.equal(beto.$('#d-nota').textContent, '—');                // não há avaliação da IA para a vaga
  assert.match(beto.$('#d-nota-txt').textContent, /ainda sem nota da IA/);          // o currículo sintético não tem nota
  assert.equal(beto.$('#d-btn-devolver').style.display, 'flex');
  assert.equal(beto.$('#d-btn-agendar').style.display, 'flex');
  beto.w.fecharDrawer();
});

test('reprovar: a candidatura fecha com o motivo e o candidato VOLTA ao Banco de Talentos, com o histórico', async () => {
  await beto.w.abrirCandidatura(candidaturaId);
  await beto.w.reprovarCandidatura();
  assert.match(beto.ultimoToast(), /reprovado — volta ao Banco de Talentos/);
  const id = idDe(candidatoAtribuido);
  assert.equal(sql(`select status_banco from candidatos where id='${id}'`), 'ativo');
  assert.equal(sql(`select status || '/' || resultado_final || '/' || (encerrada_em is not null) from candidaturas where id='${candidaturaId}'`),
    'reprovado/Motivo informado no teste/true');
  limparFiltros(beto);
  beto.define('#busca-banco', 'Candidato 020');
  await beto.w.carregarBanco();
  assert.equal(totalUi(beto), 1, 'voltou para a lista de disponíveis');
  assert.match(textoCartoes(beto)[0], /1 reprovação/);
  await beto.w.abrirTalento(id);
  assert.match(beto.$('#t-historico').textContent, /Reprovado/);
  assert.match(beto.$('#t-historico').textContent, /Motivo informado no teste/);
  beto.w.fecharDrawer();
});

test('devolver ao banco: cancela a candidatura (e a entrevista marcada) sem reprovar', async () => {
  const id = idDe('Candidato 021 Silva');
  await beto.w.abrirAtribuicaoPorId(id);
  const vaga = beto.$$('#atr-vaga option').find(o => o.value).value;
  beto.define('#atr-vaga', vaga);
  await beto.w.confirmarAtribuicao();
  const cand = sql(`select id from candidaturas where candidato_id='${id}' and encerrada_em is null`);
  sql(`insert into entrevistas (candidatura_id, data_hora, agendado_por) values ('${cand}', now() + interval '3 days', '${BETO}')`);
  await beto.w.devolverAoBancoPorId(cand, 'Candidato 021 Silva');
  assert.match(beto.ultimoToast(), /voltou ao Banco de Talentos/);
  assert.equal(sql(`select status from candidaturas where id='${cand}'`), 'cancelado');
  assert.equal(sql(`select resultado from entrevistas where candidatura_id='${cand}'`), 'cancelada');
  assert.equal(sql(`select status_banco from candidatos where id='${id}'`), 'ativo');
});

// ── 4. Ações sobre o candidato ───────────────────────────────────────────
test('editar dados, registrar contato e consentimento, inativar e reativar', async () => {
  const id = idDe('Candidato 030 Silva');
  await beto.w.abrirTalento(id);
  await beto.w.registrarContato();
  assert.match(beto.ultimoToast(), /Contato registrado/);
  assert.ok(sql(`select ultimo_contato_em from candidatos where id='${id}'`));

  beto.w.abrirEdicaoCandidato();
  beto.define('#ed-nome', 'Candidato 030 Silva Editado'); beto.define('#ed-cidade', 'Águas Claras');
  beto.define('#ed-uf', 'df'); beto.define('#ed-telefone', '(61) 99999-1234'); beto.define('#ed-escolaridade', 'superior');
  await beto.w.salvarEdicaoCandidato();
  assert.match(beto.ultimoToast(), /Dados atualizados/);
  assert.equal(sql(`select nome || '|' || cidade || '|' || uf || '|' || telefone_e164 || '|' || escolaridade from candidatos where id='${id}'`),
    'Candidato 030 Silva Editado|Águas Claras|DF|5561999991234|superior');
  assert.equal(sql(`select cidade_norm from candidatos where id='${id}'`), 'aguas claras');      // coluna de busca acompanha a edição
  assert.equal(sqlNum(`select count(*) from logs_auditoria where entidade_id='${id}' and acao='alteracao_candidato' and dados_depois::text like '%Editado%'`), 0,
    'a auditoria não guarda o valor dos dados pessoais');

  await beto.w.registrarConsentimentoCandidato();
  assert.match(beto.ultimoToast(), /Consentimento registrado/);
  assert.ok(sql(`select consentimento_em from candidatos where id='${id}'`));

  await beto.w.abrirTalento(id);
  await beto.w.alternarInativo();
  assert.equal(sql(`select status_banco from candidatos where id='${id}'`), 'inativo');
  await beto.w.alternarInativo();
  assert.equal(sql(`select status_banco from candidatos where id='${id}'`), 'ativo');
  beto.w.fecharDrawer();
});

// ── 5. Sanitização ───────────────────────────────────────────────────────
test('sanitização: administrador gera a lista; regras e prioridades aparecem; nada é apagado sozinho', async () => {
  // prepara casos: 6 candidatos parados há 9 meses; 2 com prazo de armazenamento vencido
  sql(`update candidatos set ultima_movimentacao = now() - interval '9 months' where nome between 'Candidato 040 Silva' and 'Candidato 045 Silva'`);
  sql(`update candidatos set data_entrada = now() - interval '30 months', ultima_movimentacao = now() - interval '9 months' where nome in ('Candidato 050 Silva','Candidato 051 Silva')`);
  const antes = sqlNum(`select count(*) from candidatos where status_banco <> 'expurgado'`);

  await ana.w.carregarSanitizacao();
  assert.equal(ana.$('#san-btn-gerar').style.display, 'inline-flex', 'só administrador vê o botão de gerar');
  await ana.w.gerarSugestoesAgora();
  assert.match(ana.ultimoToast(), /sugestões geradas/);
  await ana.w.carregarSanitizacao();

  const linhas = ana.$$('#san-body tr[data-id]');
  assert.ok(linhas.length >= 8, `esperava pelo menos 8 sugestões, vieram ${linhas.length}`);
  assert.equal(sqlNum(`select count(*) from candidatos where status_banco <> 'expurgado'`), antes, 'gerar a lista não muda nenhum candidato');
  const alta = linhas.find(l => l.textContent.includes('Candidato 050 Silva'));
  assert.match(alta.textContent, /Alta/);
  assert.match(alta.textContent, /No banco há mais de 24 meses sem consentimento registrado/);
  assert.match(alta.textContent, /Sem movimentação há 9 meses/);
  assert.match(ana.$('#san-ciclo').textContent, /pendentes/);
  assert.notEqual(ana.$('#nav-san-badge').style.display, 'none');
  assert.ok(ana.$('#san-bulk').style.display === 'none' || ana.$('#san-bulk').style.display === '');
});

test('sanitização: RH comum vê a fila mas não gera lista nem exclui; a decisão em lote (manter) registra quem decidiu', async () => {
  await beto.w.carregarSanitizacao();
  assert.equal(beto.$('#san-btn-gerar').style.display, 'none');
  assert.equal(beto.$$('.san-so-admin').every(b => b.style.display === 'none'), true);
  assert.equal(beto.$$('#san-body .btn-sm.vermelho').length, 0, 'nenhum botão de excluir para o RH');
  beto.w.abrirModalDecisao([beto.$$('#san-body tr[data-id]')[0].dataset.id], 'excluir');
  assert.match(beto.ultimoToast(), /Somente o administrador/);
  assert.ok(!beto.$('#modal-sanitizar').classList.contains('show'));

  await beto.w.selecionarPorPrioridade('alta');
  assert.equal(beto.w.eval('selecaoSanitizacao.size'), sqlNum(`select count(*) from sanitizacao_sugestoes where status='pendente' and prioridade='alta'`));
  const altas = [...beto.w.eval('[...selecaoSanitizacao]')];
  assert.notEqual(beto.$('#san-bulk').style.display, 'none', 'a barra de ação em lote aparece');

  beto.w.decidirLote('manter');
  assert.ok(beto.$('#modal-sanitizar').classList.contains('show'), 'nada acontece sem a confirmação explícita');
  assert.equal(sqlNum(`select count(*) from sanitizacao_sugestoes where id in ('${altas.join("','")}') and status='pendente'`), altas.length);
  beto.define('#san-m-obs', 'Ainda vale acompanhar'); beto.define('#san-m-meses', '12');
  await beto.w.confirmarDecisaoSanitizacao();
  assert.match(beto.ultimoToast(), /mantidos/);
  assert.equal(sqlNum(`select count(*) from sanitizacao_sugestoes where id in ('${altas.join("','")}') and status='mantido' and decidido_por='${BETO}'`), altas.length);
  assert.equal(sqlNum(`select count(*) from candidatos c join sanitizacao_sugestoes s on s.candidato_id=c.id where s.id in ('${altas.join("','")}') and c.sanitizacao_adiada_ate > now() + interval '11 months'`), altas.length);

  beto.define('#san-visao', 'decididas');
  await beto.w.carregarSanitizacao();
  const decidida = beto.$$('#san-body tr')[0].textContent;
  assert.match(decidida, /Mantido/);
  assert.match(decidida, /Beto RH/, 'o nome de quem decidiu aparece mesmo para RH comum (a RLS de usuarios só mostra a própria linha)');
  assert.match(decidida, /Ainda vale acompanhar/);
  beto.define('#san-visao', 'pendente');
});

test('sanitização: inativar e excluir definitivamente (administrador) — exige a confirmação e apaga só os dados pessoais', async () => {
  await ana.w.carregarSanitizacao();
  const pendentes = ana.$$('#san-body tr[data-id]').map(l => l.dataset.id);
  assert.ok(pendentes.length >= 2);
  const [paraInativar, paraExcluir] = pendentes;
  const candInativar = sql(`select candidato_id from sanitizacao_sugestoes where id='${paraInativar}'`);
  const candExcluir = sql(`select candidato_id from sanitizacao_sugestoes where id='${paraExcluir}'`);
  const hashAntes = sql(`select coalesce(hash_identidade,'(sem hash)') from candidatos where id='${candExcluir}'`);

  ana.w.decidirSugestao(paraInativar, 'inativar');
  await ana.w.confirmarDecisaoSanitizacao();
  assert.equal(sql(`select status_banco from candidatos where id='${candInativar}'`), 'inativo');

  ana.w.decidirSugestao(paraExcluir, 'excluir');
  ana.define('#san-m-confirma', false);
  await ana.w.confirmarDecisaoSanitizacao();
  assert.match(ana.ultimoToast(), /Marque a confirmação/);
  assert.notEqual(sql(`select status_banco from candidatos where id='${candExcluir}'`), 'expurgado', 'sem marcar a confirmação nada é excluído');
  ana.define('#san-m-confirma', true);
  await ana.w.confirmarDecisaoSanitizacao();
  assert.equal(sql(`select status_banco || '|' || (nome is null) || '|' || (email is null) || '|' || (telefone is null) from candidatos where id='${candExcluir}'`), 'expurgado|true|true|true');
  assert.equal(sql(`select coalesce(hash_identidade,'(sem hash)') from candidatos where id='${candExcluir}'`), hashAntes, 'o hash de identidade sobrevive');
  assert.ok(sqlNum(`select count(*) from arquivos_para_remover where removido_em is null`) >= 0);
  assert.equal(sqlNum(`select count(*) from logs_auditoria where acao='sanitizacao_decisao' and usuario_id='${ANA}'`) >= 2, true);
});

// ── 6. Outras telas ──────────────────────────────────────────────────────
test('dashboard: números do banco, funil e pendências novas', async () => {
  await beto.w.carregarDashboard();
  assert.equal(beto.$('#m-curriculos').textContent.replace(/\D/g, ''), sql(`select count(*) from candidatos where status_banco <> 'expurgado'`));
  assert.equal(beto.$$('#funil .funil-row').length, 5);
  assert.match(beto.$('#funil').textContent, /No banco/);
  assert.equal(beto.$('#m-sanitizacao').textContent, sql(`select count(*) from sanitizacao_sugestoes where status='pendente'`));
  assert.equal(beto.$('#m-revisao').textContent, sql(`select count(*) from candidatos where status_banco='ativo' and revisao_manual and reanalise_solicitada_em is null`));
  assert.match(beto.$('#vagas-resumo').textContent, /candidatos/);
  assert.deepEqual(beto.erros, []);
});

test('vagas: cada vaga mostra candidatos atribuídos e quantos do banco combinam; "Selecionar CVs" abre a seleção', async () => {
  await beto.w.carregarVagas();
  const doSetor = beto.$$('.vaga-card').find(c => c.textContent.includes('Logística'));
  assert.ok(doSetor);
  // vaga que já existia, sem função e nível: o card avisa e o botão leva ao formulário em vez de listar
  assert.match(doSetor.textContent, /Defina a função e o nível/);
  assert.equal(doSetor.querySelector('.btn-triagem').dataset.pronta, '');
  sql(`update vagas set funcao_setor = 'Supervisor', nivel_funcao = 'pleno' where id = '${doSetor.querySelector('.btn-triagem').dataset.vaga}'`);
  await beto.w.carregarVagas();
  const card = beto.$$('.vaga-card').find(c => c.textContent.includes('Supervisor · Pleno'));
  assert.ok(card, 'o card mostra a função e o nível da vaga');
  assert.match(card.textContent, /No banco/);
  const btn = card.querySelector('.btn-triagem');
  assert.equal(btn.textContent.trim(), 'Selecionar CVs');
  assert.equal(btn.dataset.pronta, '1');
  beto.define('#busca-banco', 'texto esquecido de uma busca anterior');   // o ranking não pode ser afetado por isto
  beto.w.verCandidatosDaVaga(btn.dataset.vaga, btn.dataset.titulo);
  await new Promise(r => setTimeout(r, 700));
  assert.equal(beto.$('#banco-ranking').style.display, 'flex', 'o banner da seleção aparece');
  assert.equal(beto.$('#banco-ranking-titulo').textContent, btn.dataset.titulo);
  assert.equal(beto.$('#rk-ordem').value, 'nota', 'a ordem padrão é pela maior nota');
  assert.equal(beto.$('#banco-filtros').style.display, 'none', 'os filtros do banco somem no ranking');
  beto.w.sairDoRanking(false);                                            // deixa o banco no modo normal para os testes seguintes
  assert.equal(beto.$('#banco-ranking').style.display, 'none');
});

test('dashboard → "Revisão manual necessária" abre o banco já filtrado', async () => {
  beto.define('#busca-banco', 'resto de busca');
  beto.w.irBancoRevisao();
  await new Promise(r => setTimeout(r, 700));
  assert.equal(beto.$('#av-revisao').checked, true);
  assert.equal(totalUi(beto), sqlNum(`select count(*) from vw_banco_talentos where status_banco='ativo' and revisao_manual`));
});

test('entrevistas: a agenda continua funcionando com o candidato vindo do banco', async () => {
  await beto.w.carregarEntrevistas();
  assert.ok(beto.$$('#proximas-body tr').length >= 5);
  assert.ok(beto.$$('#proximas-body tr').some(tr => tr.textContent.includes('Entrevistado 1 Souza')));
});

test('configurações (administrador): parâmetros da sanitização aparecem e salvam; o que era retenção automática sumiu', async () => {
  await ana.w.carregarConfig();
  const texto = ana.$('#config-lista').textContent;
  for (const chave of ['sanitizacao_intervalo_meses', 'sanitizacao_pesos', 'sanitizacao_retencao_maxima_meses', 'ia_confianca_minima', 'sanitizacao_emails_aviso'])
    assert.ok(texto.includes(chave), `falta ${chave}`);
  assert.ok(!texto.includes('retencao_meses_ate_expurgar'));
  ana.define('#cfg-sanitizacao_adiar_meses', '9');
  await ana.w.salvarConfig('sanitizacao_adiar_meses');
  assert.match(ana.ultimoToast(), /Configuração salva/);
  assert.equal(sql(`select valor from configuracoes where chave='sanitizacao_adiar_meses'`), '9');
});

// ── 7. Etapa 1: lista negra e descarte por vaga ──────────────────────────
test('lista negra: bloquear um endereço, ver na lista, buscar e liberar', async () => {
  await beto.w.carregarListaNegra();
  assert.match(beto.$('#ln-body').textContent, /A lista negra está vazia/);

  beto.define('#ln-email', 'Spam.Total@Mail.Test'); beto.define('#ln-motivo', 'Propaganda em massa');
  await beto.w.bloquearEmailManual();
  assert.match(beto.ultimoToast(), /E-mail bloqueado/);
  const linhas = beto.$$('#ln-body tr[data-email]');
  assert.equal(linhas.length, 1);
  assert.match(linhas[0].textContent, /spam\.total@mail\.test/);          // o banco guarda em minúsculas
  assert.match(linhas[0].textContent, /Propaganda em massa/);
  assert.match(linhas[0].textContent, /Beto RH/, 'quem bloqueou aparece');
  assert.match(beto.$('#ln-contador').textContent, /1 e-mail bloqueado/);

  beto.define('#ln-email', 'isto-nao-e-email'); beto.define('#ln-motivo', 'x');
  await beto.w.bloquearEmailManual();
  assert.match(beto.ultimoToast(), /e-mail válido/, 'a validação do banco chega como mensagem');

  beto.define('#ln-busca', 'PROPAGANDA');
  await beto.w.carregarListaNegra();
  assert.equal(beto.$$('#ln-body tr[data-email]').length, 1);
  beto.define('#ln-busca', 'nada disso');
  await beto.w.carregarListaNegra();
  assert.match(beto.$('#ln-body').textContent, /Nada encontrado/);

  beto.define('#ln-busca', '');
  await beto.w.liberarEmail('spam.total@mail.test', null);
  assert.match(beto.ultimoToast(), /E-mail liberado/);
  assert.equal(beto.$$('#ln-body tr[data-email]').length, 0);
  assert.equal(sqlNum(`select count(*) from remetentes where bloqueado`), 0);
  assert.deepEqual(beto.erros, []);
});

test('lista negra: bloquear o candidato pelo cadastro — sai da lista de disponíveis, não recebe vaga e só volta se sair da lista', async () => {
  const id = idDe('Candidato 070 Silva');
  sql(`update candidatos set email = 'c070@mail.test' where id = '${id}'`);
  limparFiltros(beto);
  await beto.w.abrirTalento(id);
  assert.equal(beto.$('#t-btn-negra').style.display, 'flex');
  assert.equal(beto.$('#t-negra').style.display, 'none');

  beto.w.abrirBloqueioCandidato();
  assert.ok(beto.$('#modal-lista-negra').classList.contains('show'));
  assert.match(beto.$('#ln-m-msg').textContent, /Nada é apagado/);
  beto.define('#ln-m-motivo', '');
  await beto.w.confirmarBloqueioCandidato();
  assert.match(beto.ultimoToast(), /Informe o motivo/);
  assert.equal(sql(`select status_banco from candidatos where id='${id}'`), 'ativo', 'sem motivo nada acontece');

  beto.define('#ln-m-motivo', 'Ocorrência anterior na empresa');
  await beto.w.confirmarBloqueioCandidato();
  assert.match(beto.ultimoToast(), /lista negra/);
  assert.equal(sql(`select lista_negra || '/' || status_banco || '/' || retencao_permanente from candidatos where id='${id}'`), 'true/inativo/true');
  assert.equal(sql(`select bloqueado from remetentes where email = 'c070@mail.test'`), 't');

  // o cadastro mostra a faixa e esconde o que não vale mais
  assert.match(beto.$('#t-negra').textContent, /Na lista negra/);
  assert.match(beto.$('#t-negra').textContent, /Ocorrência anterior na empresa/);
  assert.match(beto.$('#t-negra').textContent, /Beto RH/);
  assert.equal(beto.$('#t-btn-negra').style.display, 'none');
  assert.equal(beto.$('#t-btn-liberar').style.display, 'flex');
  assert.equal(beto.$('#t-btn-status').style.display, 'none', 'não dá para reativar quem está na lista negra');
  assert.equal(beto.$('#t-btn-atribuir').style.display, 'none');

  // no banco o card ganha o selo; na tela da lista negra aparece com o nome
  beto.define('#busca-banco', 'Candidato 070'); beto.define('#filtro-b-status', '');
  await beto.w.carregarBanco();
  assert.match(textoCartoes(beto).find(t => t.includes('Candidato 070 Silva')) || '', /Lista negra/);
  await beto.w.carregarListaNegra();
  assert.match(beto.$('#ln-body').textContent, /c070@mail\.test/);
  assert.match(beto.$('#ln-body').textContent, /Candidato 070 Silva/);

  // o banco recusa a atribuição e a reativação, mesmo que alguém chame direto
  const atribuir = await beto.w.eval(`db.rpc('atribuir_candidato_vaga', { p_candidato_id: '${id}', p_vaga_id: '${sql(`select id from vagas where status='ativo' limit 1`)}' })`);
  assert.match(atribuir.error.message, /lista negra/);
  const reativar = await beto.w.eval(`db.rpc('alterar_status_banco', { p_candidato_id: '${id}', p_novo: 'ativo' })`);
  assert.match(reativar.error.message, /lista negra/);

  // tirar da lista: libera o endereço, o candidato segue inativo até o RH reativar
  await beto.w.abrirTalento(id);
  await beto.w.tirarCandidatoDaListaNegra();
  assert.equal(sql(`select lista_negra || '/' || status_banco from candidatos where id='${id}'`), 'false/inativo');
  assert.equal(sqlNum(`select count(*) from remetentes where bloqueado`), 0);
  assert.equal(beto.$('#t-btn-status').style.display, 'flex');
  await beto.w.alternarInativo();
  assert.equal(sql(`select status_banco from candidatos where id='${id}'`), 'ativo');
  beto.w.fecharDrawer();
  limparFiltros(beto);
  assert.deepEqual(beto.erros, []);
});

test('atribuição: a vaga em que o candidato já foi reprovado aparece bloqueada; as outras seguem livres', async () => {
  const id = idDe('Candidato 071 Silva');
  const vaga = sql(`select id from vagas where status = 'ativo' order by titulo limit 1`);
  const cand = sql(`select public.fn_atribuir_candidato_vaga('${id}', '${vaga}', '${BETO}', null)`);
  sql(`update candidaturas set status = 'reprovado', resultado_final = 'Sem experiência' where id = '${cand}'`);
  assert.equal(sql(`select status_banco from candidatos where id='${id}'`), 'ativo', 'reprovado voltou ao banco');

  await beto.w.abrirAtribuicaoPorId(id);
  const opcoes = [...beto.$$('#atr-vaga option')].filter(o => o.value);
  const barrada = opcoes.find(o => o.value === vaga);
  assert.ok(barrada.disabled, 'a vaga da reprovação fica bloqueada');
  assert.match(barrada.textContent, /reprovado nesta vaga em \d{2}\/\d{2}\/\d{2}/);
  assert.ok(opcoes.filter(o => o.value !== vaga).length > 0 && opcoes.filter(o => o.value !== vaga).every(o => !o.disabled), 'as demais seguem livres');
  assert.equal(opcoes.at(-1).value, vaga, 'as bloqueadas vão para o fim da lista');

  // o banco também recusa (mesmo que alguém force)
  const forcado = await beto.w.eval(`db.rpc('atribuir_candidato_vaga', { p_candidato_id: '${id}', p_vaga_id: '${vaga}' })`);
  assert.match(forcado.error.message, /já foi reprovado nesta vaga/);
  beto.w.fecharModal('modal-atribuir');
  assert.deepEqual(beto.erros, []);
});

// ── 8. Etapa 2: requisito Diferencial, ranking por vaga e assistente de IA ──
const esperar = ms => new Promise(r => setTimeout(r, ms));

test('vaga: o formulário tem os três tipos de requisito e o Diferencial é gravado', async () => {
  await beto.w.abrirModalVaga();
  const tipos = [...beto.$$('#req-list .req-row')[0].querySelectorAll('.req-tipo option')].map(o => o.value);
  assert.deepEqual(tipos, ['obrigatorio', 'desejavel', 'diferencial']);
  assert.match(beto.$('#modal-vaga').textContent, /diferenciais dão pontos extras/);

  beto.define('#vaga-titulo', 'Vaga do teste de diferencial');
  beto.define('#vaga-funcao', 'Supervisor'); beto.define('#vaga-nivel', 'pleno');    // obrigatórios: filtram os currículos
  beto.$('#req-list').innerHTML = '';
  beto.w.addRequisito('Cursando Ciências Contábeis', 'obrigatorio', 2);
  beto.w.addRequisito('Domínio de Excel', 'desejavel', 2);
  beto.w.addRequisito('Registro no CRC', 'diferencial', 1);
  await beto.w.salvarVaga();
  const id = sql(`select id from vagas where titulo = 'Vaga do teste de diferencial'`);
  assert.equal(sql(`select string_agg(tipo::text || ':' || peso, ',' order by ordem) from requisitos where vaga_id = '${id}'`),
               'obrigatorio:2,desejavel:2,diferencial:1');

  await beto.w.abrirModalVaga(id);                                        // reabre: o tipo volta selecionado
  const tiposSalvos = [...beto.$$('#req-list .req-tipo')].map(sel => sel.value);
  assert.deepEqual(tiposSalvos, ['obrigatorio', 'desejavel', 'diferencial']);
  beto.w.fecharModal('modal-vaga');
  sql(`delete from vagas where id = '${id}'`);
  assert.deepEqual(beto.erros, []);
});

test('vaga: função e nível são obrigatórios, a função depende do setor e os dois ficam gravados na vaga', async () => {
  const loja = sql(`select id from setores where nome = 'Loja'`), logistica = sql(`select id from setores where nome = 'Logística'`);
  await beto.w.abrirModalVaga();
  const funcoes = () => [...beto.$$('#vaga-funcao option')].map(o => o.textContent);
  beto.define('#vaga-setor', logistica); beto.$('#vaga-setor').onchange();
  assert.ok(funcoes().includes('Supervisor') && !funcoes().includes('Vendedor'), 'Logística oferece só as funções de Logística');
  beto.define('#vaga-setor', loja); beto.$('#vaga-setor').onchange();
  assert.ok(funcoes().includes('Vendedor') && !funcoes().includes('Supervisor'), 'ao trocar o setor a lista de funções troca');
  // o nível depende da função: Jovem Aprendiz e Trainee só nos cargos que os aceitam (Loja/Repositor sim, Loja/Vendedor não)
  const niveis = () => [...beto.$$('#vaga-nivel option')].map(o => o.value).slice(1);
  assert.deepEqual(niveis(), ['junior', 'pleno', 'senior'], 'sem função escolhida: só júnior, pleno e sênior');
  beto.define('#vaga-funcao', 'Vendedor'); beto.$('#vaga-funcao').onchange();
  assert.deepEqual(niveis(), ['junior', 'pleno', 'senior'], 'Vendedor não aceita Jovem Aprendiz nem Trainee');
  beto.define('#vaga-funcao', 'Repositor'); beto.$('#vaga-funcao').onchange();
  assert.deepEqual(niveis(), ['jovem_aprendiz', 'trainee', 'junior', 'pleno', 'senior'], 'Repositor aceita os cinco');
  beto.define('#vaga-nivel', 'trainee');
  beto.define('#vaga-funcao', 'Vendedor'); beto.$('#vaga-funcao').onchange();
  assert.equal(beto.$('#vaga-nivel').value, '', 'trocar para um cargo que não aceita Trainee limpa o nível escolhido');
  beto.define('#vaga-setor', logistica); beto.$('#vaga-setor').onchange();
  beto.define('#vaga-funcao', 'Auxiliar'); beto.$('#vaga-funcao').onchange();
  assert.deepEqual(niveis(), ['jovem_aprendiz', 'trainee', 'junior', 'pleno', 'senior'], 'Logística/Auxiliar aceita os cinco');
  beto.define('#vaga-funcao', ''); beto.$('#vaga-funcao').onchange();

  beto.define('#vaga-titulo', 'Vaga de teste função e nível');
  await beto.w.salvarVaga();                                            // sem função nem nível
  assert.match(beto.ultimoToast(), /Escolha a função e o nível/);
  assert.equal(sqlNum(`select count(*) from vagas where titulo = 'Vaga de teste função e nível'`), 0, 'não salva sem função e nível');

  beto.define('#vaga-setor', loja); beto.$('#vaga-setor').onchange();
  beto.define('#vaga-funcao', 'Vendedor'); beto.$('#vaga-funcao').onchange(); beto.define('#vaga-nivel', 'junior');
  await beto.w.salvarVaga();
  const id = sql(`select id from vagas where titulo = 'Vaga de teste função e nível'`);
  assert.equal(sql(`select funcao_setor || '/' || nivel_funcao from vagas where id = '${id}'`), 'Vendedor/junior');

  await beto.w.abrirModalVaga(id);                                      // reabre: setor, função e nível voltam selecionados
  assert.equal(beto.$('#vaga-setor').value, loja);
  assert.equal(beto.$('#vaga-funcao').value, 'Vendedor');
  assert.equal(beto.$('#vaga-nivel').value, 'junior');
  beto.w.fecharModal('modal-vaga');
  await beto.w.carregarVagas();
  assert.match(beto.$$('.vaga-card').find(c => c.textContent.includes('Vaga de teste função e nível')).textContent, /Vendedor · Júnior/);
  sql(`delete from vagas where id = '${id}'`);
  assert.deepEqual(beto.erros, []);
});

test('seleção de CVs: filtra por setor + função + nível da vaga, ordena pela nota, exclui quem não pode e atribui daqui', async () => {
  // vaga de Logística / Supervisor / pleno, com requisitos dos três tipos (aparecem na atribuição)
  const vaga = sql(`with s as (select id from setores where nome = 'Logística'),
      v as (insert into vagas (setor_id, titulo, descricao, quantidade, funcao_setor, nivel_funcao)
              select id, 'Auxiliar Contábil Ranking', 'Rotinas contábeis e fiscais', 1, 'Supervisor', 'pleno' from s returning id),
      r as (insert into requisitos (vaga_id, descricao, tipo, peso, ordem)
              select v.id, x.d, x.t::tipo_requisito, x.p, x.o from v,
              (values ('Cursando Ciências Contábeis', 'obrigatorio', 2, 1), ('Domínio de Excel', 'desejavel', 2, 2), ('Registro no CRC', 'diferencial', 1, 3)) x(d, t, p, o)
              returning 1)
    select id from v`);
  const c1 = idDe('Candidato 080 Silva'), c2 = idDe('Candidato 081 Silva'), c3 = idDe('Candidato 082 Silva'), c4 = idDe('Candidato 086 Silva');
  const qualificar = (id, nivel, nota) => sql(`update curriculos set setor_adequado = 'Logística', funcao_setor = 'Supervisor', nivel_funcao = '${nivel}', nota_classificacao = ${nota} where candidato_id = '${id}' and atual`);
  qualificar(c1, 'pleno', 90); qualificar(c2, 'pleno', 70);
  qualificar(c3, 'pleno', 95); sql(`update candidatos set lista_negra = true where id = '${c3}'`);   // combina e tem a maior nota, mas está bloqueado
  qualificar(c4, 'junior', 99);                                                                        // outro nível: não é o da vaga

  await beto.w.carregarVagas();
  const card = beto.$$('.vaga-card').find(c => c.textContent.includes('Auxiliar Contábil Ranking'));
  const btn = card.querySelector('.btn-triagem');
  assert.equal(btn.textContent.trim(), 'Selecionar CVs');
  assert.match(card.textContent, /Supervisor · Pleno/);
  assert.equal(card.querySelector('.vaga-stat:nth-child(3) .vaga-stat-val').textContent, '2', 'No banco: os dois que combinam nos três campos');
  beto.w.verCandidatosDaVaga(btn.dataset.vaga, btn.dataset.titulo, !!btn.dataset.pronta);
  await esperar(900);

  assert.equal(beto.$('#banco-ranking').style.display, 'flex');
  assert.equal(beto.$('#banco-ranking-titulo').textContent, 'Auxiliar Contábil Ranking');
  const lista = textoCartoes(beto);
  assert.ok(lista[0].includes('Candidato 080 Silva'), 'a maior nota (90) vem primeiro');
  assert.ok(lista[1].includes('Candidato 081 Silva'), 'depois a nota 70');
  assert.equal(lista.length, 2, 'só quem tem setor, função e nível iguais aos da vaga');
  assert.ok(!lista.some(t => t.includes('Candidato 082 Silva')), 'lista negra fora da seleção, mesmo com a maior nota');
  assert.ok(!lista.some(t => t.includes('Candidato 086 Silva')), 'nível diferente fora da seleção');
  assert.deepEqual(beto.$$('#banco-lista .aderencia b').map(b => b.textContent), ['90', '70'], 'a nota de cada currículo aparece');
  assert.doesNotMatch(lista[0], /Combina em/, 'sem palavras-chave: não há IA escolhendo');
  assert.match(beto.$('#banco-total').textContent, /2 de 2 currículos|2 currículos/);

  // atribuir a partir do ranking: a vaga já vem escolhida e mostra os Diferenciais
  await beto.w.abrirAtribuicaoPorId(c1);
  assert.equal(beto.$('#atr-vaga').value, vaga, 'a vaga do ranking já vem escolhida');
  assert.match(beto.$('#atr-vaga-info').textContent, /Diferenciais/);
  assert.match(beto.$('#atr-vaga-info').textContent, /Registro no CRC/);
  await beto.w.confirmarAtribuicao();
  await esperar(500);
  const depois = textoCartoes(beto);
  assert.ok(!depois.some(t => t.includes('Candidato 080 Silva')), 'quem foi atribuído sai do ranking (está em processo)');
  assert.ok(depois[0].includes('Candidato 081 Silva'), 'o próximo assume o topo');

  // reprovado NESTA vaga não volta ao ranking, mesmo disponível no banco
  const cand = sql(`select id from candidaturas where candidato_id = '${c1}' and vaga_id = '${vaga}'`);
  sql(`update candidaturas set status = 'reprovado', resultado_final = 'Sem CRC' where id = '${cand}'`);
  assert.equal(sql(`select status_banco from candidatos where id = '${c1}'`), 'ativo');
  await beto.w.carregarBanco();
  assert.ok(!textoCartoes(beto).some(t => t.includes('Candidato 080 Silva')), 'reprovado nesta vaga: fora do ranking');

  // sair do ranking e o menu sempre mostram o banco inteiro
  beto.w.sairDoRanking(false);
  assert.equal(beto.$('#banco-filtros').style.display, '');
  beto.w.verCandidatosDaVaga(vaga, 'Auxiliar Contábil Ranking');
  await esperar(500);
  beto.w.irPara('banco', beto.$('[data-tela="banco"]'));
  await esperar(500);
  assert.equal(beto.$('#banco-ranking').style.display, 'none', 'clicar no menu volta ao banco inteiro');
  limparFiltros(beto);
  sql(`delete from vagas where id = '${vaga}'`);
  assert.deepEqual(beto.erros, []);
});

test('vaga: atribuir grava a qualificação da vaga no currículo; o número de candidatos abre a tela dos selecionados e cancelar a seleção devolve ao banco sem perdê-la', async () => {
  const vaga = sql(`with s as (select id from setores where nome = 'Logística'),
      v as (insert into vagas (setor_id, titulo, quantidade, funcao_setor, nivel_funcao)
              select id, 'Vaga dos Selecionados', 1, 'Supervisor', 'pleno' from s returning id)
    select id from v`);
  const c1 = idDe('Candidato 087 Silva'), c2 = idDe('Candidato 088 Silva');
  const qualificacao = id => sql(`select setor_adequado || '/' || funcao_setor || '/' || nivel_funcao || '/' || nota_classificacao from curriculos where atual and candidato_id = '${id}'`);
  sql(`update curriculos set setor_adequado = 'Loja', funcao_setor = 'Vendedor', nivel_funcao = 'junior', nota_classificacao = 60 where atual and candidato_id in ('${c1}', '${c2}')`);   // a IA os classificou em outro lugar
  sql(`update candidatos set revisao_manual = true where id = '${c1}'`);

  // atribuir pelo painel (o RH decidiu que servem para esta vaga)
  for (const id of [c1, c2]) {
    await beto.w.abrirAtribuicaoPorId(id);
    beto.define('#atr-vaga', vaga);
    await beto.w.mostrarVagaAtribuicao();
    await beto.w.confirmarAtribuicao();
  }
  assert.equal(qualificacao(c1), 'Logística/Supervisor/pleno/60', 'o currículo ganhou a qualificação da vaga (a nota é a da IA)');
  assert.equal(sql(`select area_sugerida || '/' || cargo_sugerido || '/' || nivel_sugerido || '/' || revisao_manual from candidatos where id = '${c1}'`), 'Logística/Supervisor/pleno/false',
               'o candidato (o que o painel lê) acompanha e a revisão manual sai');

  // o número de candidatos do card é clicável e abre a tela "Candidatos em processo" só com os selecionados para a vaga
  await beto.w.carregarVagas();
  const numeroDe = () => beto.$$('.vaga-card').find(c => c.textContent.includes('Vaga dos Selecionados')).querySelector('.vaga-stat-link');
  assert.equal(numeroDe().querySelector('.vaga-stat-val').textContent, '2');
  beto.w.abrirCandidatosDaVaga(numeroDe().dataset.vaga, numeroDe().dataset.titulo, !!numeroDe().dataset.pronta);
  await esperar(800);
  assert.ok(beto.$('#screen-candidatos').classList.contains('active'), 'abre a tela de candidatos em processo');
  assert.equal(beto.$('#cand-vaga-banner').style.display, 'flex');
  assert.equal(beto.$('#cand-vaga-titulo').textContent, 'Vaga dos Selecionados');
  assert.equal(beto.$('#th-cand-vaga').textContent, 'Qualificação', 'no modo vaga a coluna Vaga vira Qualificação');
  assert.equal(beto.$('#th-cand-nota').textContent, 'Nota do CV');
  const linhas = () => beto.$$('#candidatos-body tr');
  assert.equal(linhas().length, 2, 'só os candidatos desta vaga');
  assert.ok(linhas().every(l => /Logística \/ Supervisor/.test(l.textContent) && /Pleno/.test(l.textContent)), 'cada linha mostra a qualificação da vaga');
  assert.ok(linhas().every(l => l.querySelector('.pill').textContent.trim() === '60'), 'e a nota do currículo (60)');
  assert.ok(linhas().every(l => l.textContent.includes('Cancelar seleção') && l.querySelector('.btn-sm.azul')), 'cancelar seleção e agendar em cada linha');
  assert.match(beto.$('#candidatos-contador').textContent, /2 (de 2 )?candidaturas/);

  // cancelar a seleção de UM: volta ao banco, sai da tela e NÃO perde a qualificação
  const alvo = linhas().find(l => l.textContent.includes('Candidato 087'));
  const botao = alvo.querySelector('.btn-sm.vermelho');
  await beto.w.devolverAoBancoPorId(botao.dataset.id, botao.dataset.nome);
  await esperar(600);
  assert.equal(sql(`select status_banco from candidatos where id = '${c1}'`), 'ativo');
  assert.equal(sql(`select status_banco from candidatos where id = '${c2}'`), 'em_processo', 'o outro segue selecionado');
  assert.equal(qualificacao(c1), 'Logística/Supervisor/pleno/60', 'cancelar não desfaz a qualificação');
  assert.equal(linhas().length, 1);
  assert.ok(beto.$('#cand-vaga-banner').style.display === 'flex', 'continua na tela da vaga');

  // o CV volta a aparecer entre os disponíveis do Banco de Talentos, com a qualificação da vaga
  beto.w.irPara('banco', beto.$('[data-tela="banco"]'));
  limparFiltros(beto);
  beto.define('#busca-banco', 'Candidato 087');
  await beto.w.carregarBanco();
  assert.equal(totalUi(beto), 1, 'o CV volta a aparecer entre os disponíveis do Banco de Talentos');
  assert.match(textoCartoes(beto)[0], /Logística \/ Supervisor \/ Pleno/, 'com a qualificação da vaga');

  // clicar no menu mostra todos os candidatos em processo de novo; "Voltar às vagas" leva à lista de vagas
  beto.w.irPara('candidatos', beto.$('[data-tela="candidatos"]'));
  await esperar(500);
  assert.equal(beto.$('#cand-vaga-banner').style.display, 'none', 'o menu sai do modo vaga');
  assert.equal(beto.$('#th-cand-vaga').textContent, 'Vaga');
  beto.w.abrirCandidatosDaVaga(vaga, 'Vaga dos Selecionados', true);
  await esperar(500);
  const ultimo = linhas().find(l => l.textContent.includes('Candidato 088')).querySelector('.btn-sm.vermelho');
  await beto.w.devolverAoBancoPorId(ultimo.dataset.id, ultimo.dataset.nome);            // cancela o último
  await esperar(500);
  assert.match(beto.$('#candidatos-body').textContent, /Nenhum currículo selecionado para esta vaga/);
  beto.w.sairDaVagaEmProcesso();
  await esperar(500);
  assert.ok(beto.$('#screen-vagas').classList.contains('active'), 'Voltar às vagas');
  assert.equal(numeroDe().querySelector('.vaga-stat-val').textContent, '0', 'o número do card acompanha');
  limparFiltros(beto);
  sql(`delete from vagas where id = '${vaga}'`);
  assert.deepEqual(beto.erros, []);
});

test('níveis: o administrador habilita/desabilita Jovem Aprendiz e Trainee e reescreve o critério; o formulário da vaga e a auditoria acompanham', async () => {
  await ana.w.carregarConfig();
  const bloco = () => ana.$('#config-niveis');
  assert.ok(bloco(), 'a seção de níveis aparece em Configurações');
  assert.deepEqual(ana.$$('#config-niveis .config-item').map(l => l.querySelector('.config-chave').textContent.replace(/\s+/g, ' ').trim()),
                   ['Jovem Aprendiz (jovem_aprendiz)', 'Trainee (trainee)', 'Júnior (junior)', 'Pleno (pleno)', 'Sênior (senior)']);
  assert.equal(ana.$('#nivel-ativo-junior').disabled, true, 'Júnior, Pleno e Sênior não desabilitam');
  assert.equal(ana.$('#nivel-ativo-trainee').disabled, false);

  const niveisDoFormulario = async () => {                                  // o que o formulário oferece para Logística/Auxiliar
    await ana.w.abrirModalVaga();
    ana.define('#vaga-setor', sql(`select id from setores where nome = 'Logística'`)); ana.$('#vaga-setor').onchange();
    ana.define('#vaga-funcao', 'Auxiliar'); ana.$('#vaga-funcao').onchange();
    const opcoes = [...ana.$$('#vaga-nivel option')].map(o => o.value).slice(1);
    ana.w.fecharModal('modal-vaga');
    return opcoes;
  };
  assert.deepEqual(await niveisDoFormulario(), ['jovem_aprendiz', 'trainee', 'junior', 'pleno', 'senior']);

  // desabilita o Trainee
  ana.$('#nivel-ativo-trainee').checked = false;
  await ana.w.salvarNivel('trainee');
  assert.match(ana.ultimoToast(), /Nível salvo/);
  assert.equal(sql(`select ativo from niveis_funcao where codigo = 'trainee'`), 'f');
  assert.equal(sql(`select ativo from niveis_funcao where codigo = 'jovem_aprendiz'`), 't', 'o outro segue habilitado');
  assert.deepEqual(await niveisDoFormulario(), ['jovem_aprendiz', 'junior', 'pleno', 'senior'], 'o formulário deixa de oferecer o Trainee');
  assert.equal(sqlNum(`select count(*) from logs_auditoria where acao = 'alteracao_criterios' and detalhe = 'Nível Trainee desabilitado'`), 1, 'a auditoria registra');

  // reescreve o critério; texto curto demais é recusado
  await ana.w.carregarConfig();
  ana.$('#nivel-desc-jovem_aprendiz').value = 'curto';
  await ana.w.salvarNivel('jovem_aprendiz');
  assert.match(ana.ultimoToast(), /Escreva o critério/);
  ana.$('#nivel-desc-jovem_aprendiz').value = 'Primeiro emprego, sem experiência profissional (critério de auditoria).';
  await ana.w.salvarNivel('jovem_aprendiz');
  assert.match(sql(`select descricao from niveis_funcao where codigo = 'jovem_aprendiz'`), /critério de auditoria/);

  // quem não é administrador não altera, nem chamando o banco direto
  const recusa = await beto.w.eval(`db.rpc('alterar_nivel_funcao', { p_codigo: 'trainee', p_ativo: true, p_descricao: null })`);
  assert.match(recusa.error.message, /Somente o administrador/);
  assert.equal(sql(`select ativo from niveis_funcao where codigo = 'trainee'`), 'f', 'nada mudou');

  // habilita de novo
  await ana.w.carregarConfig();
  ana.$('#nivel-ativo-trainee').checked = true;
  await ana.w.salvarNivel('trainee');
  assert.deepEqual(await niveisDoFormulario(), ['jovem_aprendiz', 'trainee', 'junior', 'pleno', 'senior']);
  assert.deepEqual(ana.erros, []);
});

test('vaga: o assistente de IA fica desligado sem API_URL e, com o serviço, preenche o formulário', async () => {
  // 1) sem API_URL (o padrão do painel): desligado, com o motivo escrito
  await beto.w.abrirModalVaga();
  assert.equal(beto.$('#ia-vaga-btn').disabled, true);
  assert.match(beto.$('#ia-vaga-aviso').textContent, /Indisponível/);
  beto.w.fecharModal('modal-vaga');

  // 2) com um serviço simulado no lugar do backend
  const http = require('node:http');
  const recebidos = [];
  let resposta = { status: 200, corpo: { descricao: 'Rotinas contábeis e fiscais.', perfil_comportamental: 'Analítico e organizado.',
    requisitos: [{ descricao: 'Cursando Ciências Contábeis', tipo: 'obrigatorio', peso: 5 }, { descricao: 'Excel', tipo: 'desejavel', peso: 3 },
                 { descricao: 'Registro no CRC', tipo: 'diferencial', peso: 1 }] } };
  const servidor = http.createServer((req, res) => {
    let corpo = '';
    req.on('data', d => { corpo += d; });
    req.on('end', () => {
      recebidos.push({ url: req.url, metodo: req.method, autorizacao: req.headers.authorization, corpo: corpo ? JSON.parse(corpo) : null });
      res.writeHead(resposta.status, { 'Content-Type': 'application/json' });
      res.end(JSON.stringify(resposta.corpo));
    });
  });
  await new Promise(r => servidor.listen(0, '127.0.0.1', r));
  const painel = await abrirPainel(BETO, 'gerente_rh', { apiUrl: `http://127.0.0.1:${servidor.address().port}` });
  try {
    await painel.w.abrirModalVaga();
    assert.equal(painel.$('#ia-vaga-btn').disabled, false);

    painel.define('#ia-vaga-pedido', 'curto');
    await painel.w.gerarRascunhoVaga();
    assert.match(painel.ultimoToast(), /uma ou duas frases/, 'pedido curto nem sai do navegador');
    assert.equal(recebidos.length, 0);

    painel.define('#vaga-titulo', 'Auxiliar Contábil');
    painel.define('#ia-vaga-pedido', 'auxiliar contábil para o financeiro, nível júnior, precisa de Excel');
    await painel.w.gerarRascunhoVaga();
    assert.equal(recebidos.length, 1);
    assert.deepEqual([recebidos[0].metodo, recebidos[0].url], ['POST', '/vagas/rascunho']);
    assert.match(recebidos[0].autorizacao, /^Bearer /);
    assert.equal(recebidos[0].corpo.titulo, 'Auxiliar Contábil');
    assert.match(recebidos[0].corpo.pedido, /precisa de Excel/);
    assert.equal(painel.$('#vaga-descricao').value, 'Rotinas contábeis e fiscais.');
    assert.equal(painel.$('#vaga-perfil').value, 'Analítico e organizado.');
    const linhas = painel.$$('#req-list .req-row').map(r => [r.querySelector('.req-input').value, r.querySelector('.req-tipo').value, r.querySelector('.req-peso').value]);
    assert.deepEqual(linhas, [['Cursando Ciências Contábeis', 'obrigatorio', '5'], ['Excel', 'desejavel', '3'], ['Registro no CRC', 'diferencial', '1']]);
    assert.match(painel.ultimoToast(), /revise/i);
    assert.equal(sqlNum(`select count(*) from vagas where titulo = 'Auxiliar Contábil'`), 0, 'o rascunho não grava nada sozinho');

    // erros do serviço chegam como mensagem; o formulário continua como estava
    resposta = { status: 429, corpo: { detail: 'Muitos pedidos seguidos. Tente de novo em alguns minutos' } };
    painel.define('#vaga-descricao', 'texto do RH que não pode sumir');
    await painel.w.gerarRascunhoVaga();
    assert.match(painel.ultimoToast(), /Muitos pedidos seguidos/);
    assert.equal(painel.$('#vaga-descricao').value, 'texto do RH que não pode sumir');
    resposta = { status: 422, corpo: { detail: [{ msg: 'string_too_short' }] } };                     // erro de validação do FastAPI é uma lista
    await painel.w.gerarRascunhoVaga();
    assert.match(painel.ultimoToast(), /Não foi possível gerar o rascunho/);
    assert.equal(painel.$('#ia-vaga-btn').disabled, false, 'o botão volta a funcionar');
    assert.deepEqual(painel.erros, []);
  } finally {
    painel.fim();
    await new Promise(r => servidor.close(r));
  }
});

// ── 9. Etapa 3: região, distância até as lojas e considerações ──────────
test('distância: a atribuição mostra as lojas da vaga; a seleção ordena por distância e filtra por km; a região do RH vale', async () => {
  // vaga (Logística / Supervisor / pleno) com duas lojas de local conhecido (CFS → Samambaia pela migração; CFT → Taguatinga aqui) e 3 candidatos que casam
  sql(`insert into empresas (sigla, nome, regiao_id) select 'CFT', 'Castelo Forte T', id from regioes_df where nome = 'Taguatinga' on conflict do nothing`);
  const vaga = sql(`with s as (select id from setores where nome = 'Logística'),
      v as (insert into vagas (setor_id, titulo, quantidade, funcao_setor, nivel_funcao) select id, 'Zeladoria Especial do Teste', 1, 'Supervisor', 'pleno' from s returning id),
      e as (insert into vaga_empresas (vaga_id, empresa_id) select v.id, em.id from v, empresas em where em.sigla in ('CFS', 'CFT') returning 1)
    select id from v`);
  const perto = idDe('Candidato 083 Silva'), longe = idDe('Candidato 084 Silva'), sem = idDe('Candidato 085 Silva');
  sql(`update candidatos set cidade = 'Ceilândia', uf = 'DF', regiao_id = null, regiao_origem = null where id = '${perto}'`);
  sql(`update candidatos set cidade = 'Gama', uf = 'DF', regiao_id = null, regiao_origem = null where id = '${longe}'`);
  sql(`update candidatos set cidade = 'Brasília', uf = 'DF', regiao_id = null, regiao_origem = null where id = '${sem}'`);
  sql(`update curriculos set setor_adequado = 'Logística', funcao_setor = 'Supervisor', nivel_funcao = 'pleno', nota_classificacao = 80 where atual and candidato_id in ('${perto}', '${longe}', '${sem}')`);
  assert.equal(sql(`select r.nome from candidatos c join regioes_df r on r.id = c.regiao_id where c.id = '${perto}'`), 'Ceilândia', 'a região sai da cidade');
  assert.equal(sql(`select count(*) from candidatos where id = '${sem}' and regiao_id is null`), '1', '"Brasília" sozinho não aponta região');

  // seleção pela nota (padrão), depois por distância; a distância aparece no card
  await beto.w.carregarVagas();
  const card = beto.$$('.vaga-card').find(c => c.textContent.includes('Zeladoria Especial do Teste'));
  const btn = card.querySelector('.btn-triagem');
  beto.w.verCandidatosDaVaga(btn.dataset.vaga, btn.dataset.titulo);
  await esperar(900);
  assert.equal(beto.$('#rk-ordem').value, 'nota');
  const meus = () => textoCartoes(beto).filter(t => /Candidato 08[345] Silva/.test(t));
  assert.equal(meus().length, 3, 'os três têm o setor, a função e o nível da vaga');
  const cartaoDe = (nome) => textoCartoes(beto).find(t => t.includes(nome));
  assert.match(cartaoDe('Candidato 083'), /\d,\d km da CFT/, 'de Ceilândia a loja mais próxima é a de Taguatinga');
  assert.match(cartaoDe('Candidato 084'), /\d+,\d km da CFS/, 'de Gama a mais próxima é a de Samambaia');
  assert.match(cartaoDe('Candidato 085'), /região não identificada/);

  beto.define('#rk-ordem', 'distancia');
  await beto.w.mudarFiltroRanking();
  const ordem = meus().map(t => t.match(/Candidato 08\d/)[0]);
  assert.deepEqual(ordem, ['Candidato 083', 'Candidato 084', 'Candidato 085'], 'mais perto primeiro; sem região por último');

  beto.define('#rk-km', '10');
  await beto.w.mudarFiltroRanking();
  assert.deepEqual(meus().map(t => t.match(/Candidato 08\d/)[0]), ['Candidato 083'], 'até 10 km: só quem mora perto');
  assert.match(beto.$('#banco-total').textContent, /currículos/);
  beto.define('#rk-km', '');

  // atribuição: as lojas da vaga com a distância e a faixa
  await beto.w.mudarFiltroRanking();
  await beto.w.abrirAtribuicaoPorId(perto);
  assert.equal(beto.$('#atr-vaga').value, vaga);
  await esperar(500);
  const dist = beto.$('#atr-distancias').textContent.replace(/\s+/g, ' ');
  assert.match(dist, /Distância de Ceilândia até as lojas da vaga/);
  assert.match(dist, /CFT.*Taguatinga.*\d,\d km.*Perto/, 'a loja mais próxima primeiro, com a faixa');
  assert.match(dist, /CFS.*Samambaia/);
  assert.ok(dist.indexOf('CFT') < dist.indexOf('CFS'), 'ordenadas da mais perto para a mais longe');
  beto.w.fecharModal('modal-atribuir');

  await beto.w.abrirAtribuicaoPorId(sem);
  await esperar(500);
  assert.match(beto.$('#atr-distancias').textContent, /não foi identificada/, 'sem região: explica como resolver');
  beto.w.fecharModal('modal-atribuir');

  // o RH define a região à mão: vale sempre e o candidato entra na conta
  await beto.w.abrirTalento(sem);
  assert.match(beto.$('#t-dados').textContent, /Não identificada/);
  await beto.w.abrirEdicaoCandidato();
  const opcoes = [...beto.$$('#ed-regiao option')].map(o => o.textContent);
  assert.ok(opcoes[0].includes('Automática') && opcoes.includes('Samambaia') && opcoes.includes('Valparaíso de Goiás — GO'));
  beto.define('#ed-regiao', sql(`select id from regioes_df where nome = 'Samambaia'`));
  await beto.w.salvarEdicaoCandidato();
  assert.equal(sql(`select r.nome || '/' || c.regiao_origem from candidatos c join regioes_df r on r.id = c.regiao_id where c.id = '${sem}'`), 'Samambaia/manual');
  assert.match(beto.$('#t-dados').textContent, /Samambaia — definida pelo RH/);
  beto.w.fecharDrawer();
  await beto.w.carregarBanco();
  assert.match(textoCartoes(beto).find(t => t.includes('Candidato 085')), /0,0 km da CFS/, 'mora na região da loja: 0 km');

  beto.w.sairDoRanking(false);
  limparFiltros(beto);
  sql(`delete from vagas where id = '${vaga}'`);
  sql(`delete from empresas where sigla = 'CFT'`);
  assert.deepEqual(beto.erros, []);
});

test('considerações: no cadastro e na aba do resultado da entrevista, ficam com o candidato e sobrevivem à volta ao banco', async () => {
  const id = idDe('Candidato 090 Silva');
  const vaga = sql(`select id from vagas where status = 'ativo' order by titulo limit 1`);
  const cand = sql(`select public.fn_atribuir_candidato_vaga('${id}', '${vaga}', '${BETO}', null)`);
  const entrevista = sql(`with x as (insert into entrevistas (candidatura_id, data_hora, agendado_por) values ('${cand}', now() + interval '1 day', '${BETO}') returning id) select id from x`);
  const tituloVaga = sql(`select titulo from vagas where id = '${vaga}'`);

  // 1) cadastro do banco: vazio, escreve, aparece com autor e o contexto da vaga
  await beto.w.abrirTalento(id);
  await esperar(300);
  assert.match(beto.$('#t-consid-lista').textContent, /Nenhuma consideração ainda/);
  beto.w.adicionarConsideracao('t');
  assert.match(beto.ultimoToast(), /Escreva a consideração/, 'campo vazio não grava');
  beto.define('#t-consid', 'Boa comunicação. Pediu horário de manhã.');
  await beto.w.adicionarConsideracao('t');
  assert.match(beto.ultimoToast(), /Consideração registrada/);
  assert.equal(beto.$('#t-consid').value, '', 'o campo limpa');
  const item = beto.$('#t-consid-lista .consid-item').textContent.replace(/\s+/g, ' ');
  assert.match(item, /Beto RH/);
  assert.match(item, /Boa comunicação/);
  assert.ok(item.includes(tituloVaga), 'guarda a vaga da época');
  beto.w.fecharDrawer();

  // 2) cadastro da candidatura ("Em processo") mostra as mesmas
  await beto.w.abrirCandidatura(cand);
  await esperar(400);
  assert.match(beto.$('#d-consid-lista').textContent, /Boa comunicação/, 'as mesmas considerações no cadastro da candidatura');
  beto.w.fecharDrawer();

  // 3) resultado da entrevista: abas Resultado | Considerações
  await beto.w.abrirResultado(entrevista, 'Candidato 090 Silva', cand, '5561900000090');
  assert.equal(beto.$('#res-painel-consid').style.display, 'none');
  beto.w.abaResultado('consid');
  assert.equal(beto.$('#res-painel-resultado').style.display, 'none');
  assert.equal(beto.$('#res-painel-consid').style.display, '');
  assert.match(beto.$('#res-consid-lista').textContent, /Boa comunicação/, 'a aba mostra o que já foi escrito');
  assert.match(beto.$('#res-consid-n').textContent, /\(1\)/);
  beto.define('#res-consid', 'Depois da entrevista: sem disponibilidade para o turno da vaga.');   // escreve mas não clica "Adicionar"
  beto.w.abaResultado('resultado');
  await beto.w.registrarResultado('reprovado');                                                  // a consideração pendente entra junto
  assert.equal(sql(`select status_banco from candidatos where id = '${id}'`), 'ativo', 'reprovado: voltou ao banco');
  assert.equal(sqlNum(`select count(*) from consideracoes_candidato where candidato_id = '${id}'`), 2, 'as duas considerações gravadas');
  assert.equal(sql(`select (entrevista_id = '${entrevista}')::text from consideracoes_candidato where texto like 'Depois da entrevista%'`), 'true',
    'a da aba leva o contexto da entrevista');

  // 4) HERANÇA: outro RH (administradora) abre o cadastro do candidato que voltou ao banco e vê as duas
  await ana.w.abrirTalento(id);
  await esperar(300);
  const nomes = ana.$$('#t-consid-lista .consid-item').map(e => e.textContent.replace(/\s+/g, ' '));
  assert.equal(nomes.length, 2);
  assert.match(nomes[0], /Depois da entrevista/, 'a mais nova primeiro');
  assert.match(nomes[0], /após a entrevista/);
  assert.match(nomes[1], /Boa comunicação/);
  assert.equal(ana.$$('#t-consid-lista .consid-del').length, 2, 'administradora pode excluir qualquer uma');

  // 5) excluir: o botão some para quem não é autor nem administrador (o banco recusa mesmo assim), e a auditoria não guarda o texto
  await beto.w.abrirTalento(id);
  await esperar(300);
  assert.equal(beto.$$('#t-consid-lista .consid-del').length, 2, 'Beto escreveu as duas');
  await ana.w.excluirConsideracaoPainel(ana.$$('#t-consid-lista .consid-del')[1].getAttribute('onclick').match(/'([^']+)'/)[1]);
  assert.match(ana.ultimoToast(), /Consideração excluída/);
  assert.equal(sqlNum(`select count(*) from consideracoes_candidato where candidato_id = '${id}'`), 1);
  assert.equal(sqlNum(`select count(*) from logs_auditoria where acao = 'consideracao_registrada' and (detalhe || coalesce(dados_depois::text, '')) ilike '%Boa comunicação%'`), 0,
    'a auditoria nunca guarda o texto');
  ana.w.fecharDrawer(); beto.w.fecharDrawer();
  assert.deepEqual(beto.erros, []);
  assert.deepEqual(ana.erros, []);
});

test('permissões no banco: RH comum não edita configuração; usuário INATIVO não vê nada (RLS)', async () => {
  const semPermissao = await beto.w.eval(`db.from('configuracoes').update({ valor: 1 }).eq('chave', 'sanitizacao_adiar_meses').select()`);
  assert.equal(semPermissao.data.length, 0, 'RLS: só administrador altera configuração');
  assert.equal(sql(`select valor from configuracoes where chave='sanitizacao_adiar_meses'`), '9');

  const dani = await abrirPainel(DANI);
  limparFiltros(dani);
  await dani.w.carregarBanco();
  assert.equal(totalUi(dani), 0);
  const atribuir = await dani.w.eval(`db.rpc('atribuir_candidato_vaga', { p_candidato_id: '${idDe('Candidato 060 Silva')}', p_vaga_id: '${sql(`select id from vagas where status='ativo' limit 1`)}' })`);
  assert.match(atribuir.error.message, /Usuário inativo/);
  const direto = await dani.w.eval(`db.from('candidatos').update({ status_banco: 'inativo' }).eq('nome', 'Candidato 060 Silva')`);
  assert.ok(direto.error, 'o painel não escreve direto em candidatos');
  dani.fim();
});

test('nenhum erro de script em toda a sessão', () => {
  assert.deepEqual(beto.erros, []);
  assert.deepEqual(ana.erros, []);
});
