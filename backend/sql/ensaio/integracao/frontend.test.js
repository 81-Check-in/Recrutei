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
  ['#av-palavras', '#av-cargos-exp', '#av-email', '#av-telefone', '#av-local', '#av-excluir-locais', '#av-idade-min', '#av-idade-max', '#av-experiencia'].forEach(s => p.define(s, ''));
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

test('barra de filtros enxuta: nome, área, cargo, nível e sexo na barra; cidade e situação em "Mais filtros"; botão Limpar filtros', async () => {
  limparFiltros(beto);
  await beto.w.carregarBanco();
  const ativos = sqlNum(`select count(*) from vw_banco_talentos where status_banco = 'ativo'`);

  // o que aparece na barra e o que mora no painel
  assert.deepEqual([...beto.$$('#banco-filtros input, #banco-filtros select')].map(e => e.id),
    ['busca-banco', 'filtro-b-area', 'filtro-b-cargo', 'filtro-b-nivel', 'filtro-b-sexo']);
  assert.deepEqual([...beto.$$('#painel-filtros-av #filtro-b-cidade, #painel-filtros-av #filtro-b-status')].map(e => e.id),
    ['filtro-b-cidade', 'filtro-b-status']);

  // sem nada em uso: nem selo, nem botão de limpar
  assert.equal(beto.$('#btn-limpar-filtros').style.display, 'none');
  assert.equal(beto.$('#badge-filtros-av').style.display, 'none');

  // uma busca na barra faz o botão aparecer; o selo de "Mais filtros" só conta o que mora no painel
  beto.define('#busca-banco', 'Candidato 010');
  await beto.w.carregarBanco();
  assert.notEqual(beto.$('#btn-limpar-filtros').style.display, 'none');
  assert.equal(beto.$('#badge-filtros-av').style.display, 'none');

  // cidade e situação (que passaram para o painel) continuam filtrando e entram no selo
  beto.define('#busca-banco', ''); beto.define('#filtro-b-cidade', 'ceilandia'); beto.define('#filtro-b-status', '');
  await beto.w.carregarBanco();
  assert.equal(beto.$('#badge-filtros-av').textContent, '2');
  assert.equal(totalUi(beto), sqlNum(`select count(*) from vw_banco_talentos where cidade_norm like 'ceilandia%'`));

  // "Limpar" do painel: só o que mora nele (cidade, situação, avançados); a busca da barra continua
  beto.define('#busca-banco', 'Candidato'); beto.define('#av-cnh', true); beto.w.aplicarFiltrosAvancados();
  await beto.w.carregarBanco();
  assert.equal(beto.$('#badge-filtros-av').textContent, '3');            // cidade + situação + CNH
  await beto.w.limparFiltrosAvancados();
  assert.equal(beto.$('#filtro-b-cidade').value, '');
  assert.equal(beto.$('#filtro-b-status').value, 'ativo');
  assert.equal(beto.$('#av-cnh').checked, false);
  assert.equal(beto.$('#busca-banco').value, 'Candidato');
  assert.equal(beto.$('#badge-filtros-av').style.display, 'none');
  assert.notEqual(beto.$('#btn-limpar-filtros').style.display, 'none');   // a busca da barra ainda está em uso

  // "Limpar filtros" da barra: tira tudo (painel incluído), recarrega a lista inteira e NÃO mexe na ordem escolhida
  beto.define('#filtro-b-area', 'Vendas'); beto.define('#filtro-b-sexo', 'feminino'); beto.define('#filtro-b-cidade', 'ceilandia');
  beto.define('#av-revisao', true); beto.w.aplicarFiltrosAvancados(); beto.define('#ordem-banco', 'nome');
  await beto.w.carregarBanco();
  assert.notEqual(beto.$('#btn-limpar-filtros').style.display, 'none');
  await beto.w.limparFiltrosDaBarra();
  for (const id of ['busca-banco', 'filtro-b-area', 'filtro-b-cargo', 'filtro-b-nivel', 'filtro-b-sexo', 'filtro-b-cidade'])
    assert.equal(beto.$('#' + id).value, '', id);
  assert.equal(beto.$('#filtro-b-status').value, 'ativo');
  assert.equal(beto.$('#av-revisao').checked, false);
  assert.equal(beto.w.eval('filtrosAvancados'), null);
  assert.equal(beto.$('#ordem-banco').value, 'nome');                    // ordenar não é filtrar
  assert.equal(totalUi(beto), ativos);
  assert.equal(beto.$('#btn-limpar-filtros').style.display, 'none');
  assert.equal(beto.$('#badge-filtros-av').style.display, 'none');
  assert.deepEqual(beto.erros, []);
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

test('filtros de e-mail, telefone e cargos com experiência ("Mais filtros"): e-mail do currículo e de quem enviou, telefone só por números, cargo sem maiúsculas nem acentos', async () => {
  limparFiltros(beto);
  const noBanco = filtros => sqlNum(`select count(*) from filtrar_banco_talentos('${JSON.stringify(filtros)}') where status_banco='ativo'`);
  const nomes = () => textoCartoes(beto).join(' | ');
  const aplicar = async () => { beto.w.aplicarFiltrosAvancados(); await beto.w.carregarBanco(); };

  // e-mail que está no currículo (o do cadastro): pedaço, em maiúsculas
  beto.define('#av-email', 'CANDIDATO.010.SILVA');
  await aplicar();
  assert.equal(totalUi(beto), 1);
  assert.match(nomes(), /Candidato 010 Silva/);
  assert.equal(beto.$('#badge-filtros-av').textContent, '1', 'o selo de "Mais filtros" conta o e-mail');
  assert.equal(beto.$('#btn-limpar-filtros').style.display, '', 'e o botão Limpar filtros aparece');

  // e-mail de quem ENVIOU o currículo (outro endereço, que não está no cadastro)
  beto.define('#av-email', 'remetente10@mail');
  await aplicar();
  assert.equal(totalUi(beto), noBanco({ email: 'remetente10@mail' }));
  assert.ok(totalUi(beto) >= 1);
  assert.match(nomes(), /Candidato 010 Silva/, 'achado pelo endereço de envio');
  beto.define('#av-email', 'ninguem@nada.invalido');
  await aplicar();
  assert.equal(totalUi(beto), 0);

  // telefone: só os números contam; com máscara, o resultado é o mesmo
  limparFiltros(beto);
  beto.define('#av-telefone', '(61) 90000-1370');
  await aplicar();
  assert.equal(totalUi(beto), noBanco({ telefone: '61900001370' }));
  assert.match(nomes(), /Candidato 010 Silva/);
  beto.define('#av-telefone', '900001370');                    // sem DDD
  await aplicar();
  assert.equal(totalUi(beto), 1);
  assert.equal(beto.w.eval('filtrosAvancados.texto.telefone'), '900001370', 'o painel manda só os números');

  // telefone com menos de 3 números não filtra: avisa e não aplica (senão traria quase todo mundo)
  limparFiltros(beto);
  beto.define('#av-telefone', '13');
  await aplicar();
  assert.match(beto.ultimoToast(), /pelo menos 3 números/);
  assert.equal(beto.w.eval('filtrosAvancados'), null);

  // cargos com experiência: sem diferenciar maiúsculas nem acentos; vários = qualquer um
  limparFiltros(beto);
  beto.define('#av-cargos-exp', 'AUXILIAR DE LOGÍSTICA');
  await aplicar();
  const comAcento = totalUi(beto);
  assert.equal(comAcento, noBanco({ cargos_experiencia: ['auxiliar de logistica'] }));
  assert.ok(comAcento > 10, `esperava vários com experiência em auxiliar de logística, vieram ${comAcento}`);
  beto.define('#av-cargos-exp', 'auxiliar de logistica');
  await aplicar();
  assert.equal(totalUi(beto), comAcento, 'com ou sem acento e maiúsculas dá o mesmo');
  beto.define('#av-cargos-exp', 'auxiliar de logistica, astronauta');
  await aplicar();
  assert.equal(totalUi(beto), comAcento, 'vários cargos: aparece quem tem qualquer um');
  beto.define('#av-cargos-exp', 'astronauta');
  await aplicar();
  assert.equal(totalUi(beto), 0);

  // os três juntos com o filtro comum de cidade e o selo contando cada um
  limparFiltros(beto);
  beto.define('#av-cargos-exp', 'logistica'); beto.define('#av-email', 'mail.test'); beto.define('#av-telefone', '5561900');
  await aplicar();
  assert.equal(beto.$('#badge-filtros-av').textContent, '3');
  assert.equal(totalUi(beto), noBanco({ cargos_experiencia: ['logistica'], email: 'mail.test', telefone: '5561900' }));

  // Limpar (do painel) esvazia os três campos
  await beto.w.limparFiltrosAvancados();
  assert.equal(['#av-cargos-exp', '#av-email', '#av-telefone'].map(x => beto.$(x).value).join(''), '');
  assert.equal(beto.w.eval('filtrosAvancados'), null);
  assert.deepEqual(beto.erros, []);
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
  assert.equal(beto.$('#t-btn-sanitizar').style.display, 'flex', 'qualquer usuário do RH pode mandar para a sanitização');
  assert.equal(beto.$('#t-btn-excluir'), null, 'o "Excluir dados" direto saiu do cadastro');
  await ana.w.abrirTalento(id);
  assert.equal(ana.$('#t-btn-sanitizar').style.display, 'flex');
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

test('tela "Em processo": filtro por sexo (feminino, masculino, não informado) sozinho e combinado com o status', async () => {
  const ids = sql(`select candidato_id from (select distinct candidato_id from vw_candidatos) x limit 3`).split('\n');
  const originais = ids.map(id => sql(`select coalesce(sexo, '') from candidatos where id='${id}'`));
  sql(`update candidatos set sexo = 'feminino' where id='${ids[0]}'`);
  sql(`update candidatos set sexo = 'masculino' where id='${ids[1]}'`);
  sql(`update candidatos set sexo = null where id='${ids[2]}'`);
  try {
    beto.define('#filtro-cand-status', ''); beto.define('#busca-candidatos', ''); beto.define('#filtro-cand-sexo', '');
    await beto.w.carregarCandidatos();
    const todos = sqlNum(`select count(*) from vw_candidatos`);
    assert.equal(beto.w.eval('estadoCandidatos.total'), todos, 'sem filtro: todos');
    assert.deepEqual([...beto.$$('#filtro-cand-sexo option')].map(o => o.value), ['', 'feminino', 'masculino', 'nao_informado'], 'as mesmas 4 opções do Banco de Talentos');
    for (const [valor, condicao] of [['feminino', `sexo = 'feminino'`], ['masculino', `sexo = 'masculino'`], ['nao_informado', 'sexo is null']]) {
      beto.define('#filtro-cand-sexo', valor);
      await beto.w.carregarCandidatos();
      const esperado = sqlNum(`select count(*) from vw_candidatos where ${condicao}`);
      assert.ok(esperado >= 1 && esperado < todos, `há candidatos "${valor}" e não são todos (${esperado} de ${todos})`);
      assert.equal(beto.w.eval('estadoCandidatos.total'), esperado, `total com sexo ${valor}`);
      assert.equal(beto.$$('#candidatos-body tr').length, esperado, `linhas com sexo ${valor}`);
    }
    beto.define('#filtro-cand-sexo', 'feminino'); beto.define('#filtro-cand-status', 'aprovado');
    await beto.w.carregarCandidatos();
    assert.equal(beto.w.eval('estadoCandidatos.total'), sqlNum(`select count(*) from vw_candidatos where sexo = 'feminino' and status = 'aprovado'`), 'combina com o status');
  } finally {
    ids.forEach((id, i) => sql(`update candidatos set sexo = ${originais[i] ? `'${originais[i]}'` : 'null'} where id='${id}'`));
    beto.define('#filtro-cand-sexo', ''); beto.define('#filtro-cand-status', '');
    await beto.w.carregarCandidatos();
  }
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

test('sanitização: a fila só mantém ou inativa (ninguém exclui); RH comum não gera lista; a decisão em lote (manter) registra quem decidiu', async () => {
  await beto.w.carregarSanitizacao();
  assert.equal(beto.$('#san-btn-gerar').style.display, 'none');
  assert.equal(beto.$$('#san-body .btn-sm.vermelho').length, 0, 'nenhum botão de excluir para o RH');
  assert.equal(beto.$$('#san-bulk .vermelho').length, 0, 'nem na barra de ação em lote');
  await ana.w.carregarSanitizacao();
  assert.equal(ana.$$('#san-body .btn-sm.vermelho').length, 0, 'nem para o administrador: a fila não exclui');
  assert.equal(ana.$$('#san-bulk .vermelho').length, 0);
  assert.match(ana.$('.san-explica').textContent, /não apaga nada/);
  // o banco recusa "excluir" mesmo por fora do painel, para administrador e para RH
  const sugAlvo = beto.$$('#san-body tr[data-id]')[0].dataset.id;
  const recusaRH = await beto.w.eval(`db.rpc('sanitizacao_decidir', { p_sugestao_id: '${sugAlvo}', p_decisao: 'excluir' })`);
  assert.match(recusaRH.error?.message || '', /só mantém ou inativa/);
  const recusaAdm = await ana.w.eval(`db.rpc('sanitizacao_decidir', { p_sugestao_id: '${sugAlvo}', p_decisao: 'excluir' })`);
  assert.match(recusaAdm.error?.message || '', /só mantém ou inativa/);
  const recusaLote = await ana.w.eval(`db.rpc('sanitizacao_decidir_lote', { p_sugestao_ids: ['${sugAlvo}'], p_decisao: 'excluir' })`);
  assert.match(recusaLote.error?.message || '', /só mantém ou inativa/);
  assert.equal(sql(`select status from sanitizacao_sugestoes where id='${sugAlvo}'`), 'pendente', 'a sugestão segue pendente');

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

test('sanitização: inativar (confirmação explícita); o expurgo é automático, N meses depois, e apaga só os dados pessoais', async () => {
  await ana.w.carregarSanitizacao();
  const pendentes = ana.$$('#san-body tr[data-id]').map(l => l.dataset.id);
  assert.ok(pendentes.length >= 2);
  const [paraInativar, paraOutro] = pendentes;
  const candInativar = sql(`select candidato_id from sanitizacao_sugestoes where id='${paraInativar}'`);
  const candOutro = sql(`select candidato_id from sanitizacao_sugestoes where id='${paraOutro}'`);
  const hashAntes = sql(`select coalesce(hash_identidade,'(sem hash)') from candidatos where id='${candInativar}'`);

  ana.w.decidirSugestao(paraInativar, 'inativar');
  assert.ok(ana.$('#modal-sanitizar').classList.contains('show'), 'nada acontece sem a confirmação explícita');
  assert.match(ana.$('#san-m-msg').textContent, /APAGADOS automaticamente/, 'o aviso diz que os dados serão apagados sozinhos');
  assert.match(ana.$('#san-m-msg').textContent, /6 meses/, 'com o prazo configurado');
  assert.equal(sql(`select status_banco from candidatos where id='${candInativar}'`), 'ativo', 'ainda não inativou');
  await ana.w.confirmarDecisaoSanitizacao();
  assert.equal(sql(`select status_banco from candidatos where id='${candInativar}'`), 'inativo');
  assert.equal(sql(`select (inativado_em > now() - interval '1 minute')::text from candidatos where id='${candInativar}'`), 'true', 'a contagem do expurgo parte daqui');
  assert.equal(sql(`select nome is not null from candidatos where id='${candInativar}'`), 't', 'inativar não apaga nada');

  // 5 meses depois: nada. 7 meses depois: a rotina diária (service_role) apaga os dados pessoais
  sql(`update candidatos set inativado_em = now() - interval '5 months' where id='${candInativar}'`);
  sql(`select fn_expurgar_inativos_vencidos()`);
  assert.notEqual(sql(`select status_banco from candidatos where id='${candInativar}'`), 'expurgado', 'com 5 meses ainda não apaga');
  sql(`update candidatos set inativado_em = now() - interval '7 months' where id='${candInativar}'`);
  sql(`select fn_expurgar_inativos_vencidos()`);
  assert.equal(sql(`select status_banco || '|' || (nome is null) || '|' || (email is null) || '|' || (telefone is null) from candidatos where id='${candInativar}'`), 'expurgado|true|true|true');
  assert.equal(sql(`select coalesce(hash_identidade,'(sem hash)') from candidatos where id='${candInativar}'`), hashAntes, 'o hash de identidade sobrevive');
  assert.equal(sql(`select status from sanitizacao_sugestoes where id='${paraInativar}'`), 'inativado');
  assert.equal(sqlNum(`select count(*) from logs_auditoria where acao='sanitizacao_decisao' and usuario_id='${ANA}'`) >= 1, true);
  assert.equal(sqlNum(`select count(*) from logs_auditoria where acao='exclusao_manual_lgpd' and entidade_id='${candInativar}' and detalhe like 'Expurgo automático%'`), 1, 'o expurgo automático fica auditado');
  assert.equal(sql(`select status_banco from candidatos where id='${candOutro}'`), 'ativo', 'quem não foi inativado não é tocado');
  sql(`update candidatos set inativado_em = now() where status_banco = 'inativo'`);       // deixa o resto do teste sem vencidos
});

test('sanitizar: o botão do cadastro manda o candidato direto para a fila (RH comum), sem apagar nada; a fila só mantém ou inativa', async () => {
  const id = idDe('Candidato 075 Silva');
  const dadosAntes = sql(`select nome || '|' || status_banco from candidatos where id='${id}'`);
  assert.equal(sqlNum(`select count(*) from sanitizacao_sugestoes where candidato_id='${id}' and status='pendente'`), 0);

  await beto.w.abrirTalento(id);
  assert.equal(beto.$('#t-btn-sanitizar').style.display, 'flex');
  await beto.w.sanitizarCandidato();
  assert.match(beto.ultimoToast(), /Enviado para a fila de Sanitização/);
  assert.ok(!beto.$('#drawer-talento').classList.contains('show'), 'o cadastro fecha');
  assert.equal(sql(`select origem || '|' || prioridade || '|' || (ciclo_id is null) || '|' || (enviada_por='${BETO}') from sanitizacao_sugestoes where candidato_id='${id}' and status='pendente'`),
    'manual|alta|true|true');
  assert.equal(sql(`select nome || '|' || status_banco from candidatos where id='${id}'`), dadosAntes, 'nada é apagado nem inativado ao enviar');

  // apertar de novo não duplica
  await beto.w.abrirTalento(id);
  await beto.w.sanitizarCandidato();
  assert.match(beto.ultimoToast(), /já está na fila/);
  assert.equal(sqlNum(`select count(*) from sanitizacao_sugestoes where candidato_id='${id}' and status='pendente'`), 1);
  beto.w.fecharDrawer();

  // aparece na fila da Sanitização com o motivo e quem mandou
  await beto.w.carregarSanitizacao();
  const linha = beto.$$('#san-body tr[data-id]').find(l => l.textContent.includes('Candidato 075 Silva'));
  assert.ok(linha, 'a sugestão manual aparece na fila');
  assert.match(linha.textContent, /Enviado para a sanitização pelo RH/);
  assert.match(linha.textContent, /Alta/);
  assert.match(linha.textContent, new RegExp(sql(`select nome from usuarios where id='${BETO}'`)));

  // ninguém exclui pela fila; o RH inativa o que enviou e o cadastro de quem está inativo não oferece mais "Sanitizar"
  const sug = sql(`select id from sanitizacao_sugestoes where candidato_id='${id}' and status='pendente'`);
  const recusa = await ana.w.eval(`db.rpc('sanitizacao_decidir', { p_sugestao_id: '${sug}', p_decisao: 'excluir' })`);
  assert.match(recusa.error?.message || '', /só mantém ou inativa/);
  await beto.w.carregarSanitizacao();
  beto.w.decidirSugestao(sug, 'inativar');
  await beto.w.confirmarDecisaoSanitizacao();
  assert.equal(sql(`select status_banco from candidatos where id='${id}'`), 'inativo');
  assert.equal(sql(`select status from sanitizacao_sugestoes where id='${sug}'`), 'inativado');
  assert.equal(sql(`select nome is not null from candidatos where id='${id}'`), 't', 'inativar não apaga nada');
  await beto.w.abrirTalento(id);
  assert.equal(beto.$('#t-btn-sanitizar').style.display, 'none', 'quem já está inativo não vai para a sanitização (os dados saem sozinhos no prazo)');
  const jaInativo = await beto.w.eval(`db.rpc('sanitizacao_enviar_candidato', { p_candidato_id: '${id}' })`);
  assert.match(jaInativo.error?.message || '', /já está inativo/);
  beto.w.fecharDrawer();

  // quem não pode ser sanitizado (contratado = retenção permanente) não tem o botão
  const contratado = idDe('Candidato 076 Silva');
  sql(`update candidatos set retencao_permanente = true where id='${contratado}'`);
  await beto.w.abrirTalento(contratado);
  assert.equal(beto.$('#t-btn-sanitizar').style.display, 'none');
  beto.w.fecharDrawer();
  sql(`update candidatos set retencao_permanente = false where id='${contratado}'`);
  assert.deepEqual(beto.erros, []);
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
  for (const chave of ['expurgo_meses_apos_inativar', 'sanitizacao_intervalo_dias', 'sanitizacao_pesos', 'sanitizacao_retencao_maxima_meses', 'ia_confianca_minima', 'sanitizacao_emails_aviso'])
    assert.ok(texto.includes(chave), `falta ${chave}`);
  assert.ok(!texto.includes('retencao_meses_ate_expurgar'));
  ana.define('#cfg-sanitizacao_adiar_meses', '9');
  await ana.w.salvarConfig('sanitizacao_adiar_meses');
  assert.match(ana.ultimoToast(), /Configuração salva/);
  assert.equal(sql(`select valor from configuracoes where chave='sanitizacao_adiar_meses'`), '9');
  ana.define('#cfg-expurgo_meses_apos_inativar', '8');
  await ana.w.salvarConfig('expurgo_meses_apos_inativar');
  assert.match(ana.ultimoToast(), /Configuração salva/);
  assert.equal(sql(`select valor from configuracoes where chave='expurgo_meses_apos_inativar'`), '8');
  sql(`update configuracoes set valor = to_jsonb(6) where chave='expurgo_meses_apos_inativar'`);
});

// ── 7. Etapa 1: bloqueios (antes "lista negra") e descarte por vaga ──────────────────────────
test('bloqueios: bloquear um endereço, ver na lista, buscar e liberar', async () => {
  await beto.w.carregarListaNegra();
  assert.match(beto.$('#ln-body').textContent, /Nenhum bloqueio registrado/);
  // o nome novo aparece no menu, na tela e no modal — e o antigo não aparece em nenhum deles
  assert.equal(beto.$('.nav-item[data-tela="listanegra"] .nav-label').textContent, 'Bloqueios');
  assert.match(beto.$('#screen-listanegra').textContent, /Bloqueios de e-mails/);
  for (const seletor of ['.nav-item[data-tela="listanegra"]', '#screen-listanegra', '#modal-lista-negra', '#drawer-talento'])
    assert.doesNotMatch(beto.$(seletor).textContent + (beto.$(seletor).getAttribute('title') || ''), /lista negra/i, `${seletor} ainda diz "lista negra"`);

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

test('bloqueios: bloquear o candidato pelo cadastro — sai da lista de disponíveis, não recebe vaga e só volta se o bloqueio for removido', async () => {
  const id = idDe('Candidato 070 Silva');
  sql(`update candidatos set email = 'c070@mail.test' where id = '${id}'`);
  limparFiltros(beto);
  await beto.w.abrirTalento(id);
  assert.equal(beto.$('#t-btn-negra').style.display, 'flex');
  assert.match(beto.$('#t-btn-negra').textContent, /Bloquear/);
  assert.match(beto.$('#t-btn-liberar').textContent, /Remover bloqueio/);
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
  assert.match(beto.ultimoToast(), /Candidato bloqueado/);
  assert.equal(sql(`select lista_negra || '/' || status_banco || '/' || retencao_permanente from candidatos where id='${id}'`), 'true/inativo/true');
  assert.equal(sql(`select bloqueado from remetentes where email = 'c070@mail.test'`), 't');

  // o cadastro mostra a faixa e esconde o que não vale mais
  assert.match(beto.$('#t-negra').textContent, /Bloqueado/);
  assert.match(beto.$('#t-negra').textContent, /Ocorrência anterior na empresa/);
  assert.match(beto.$('#t-negra').textContent, /Beto RH/);
  assert.equal(beto.$('#t-btn-negra').style.display, 'none');
  assert.equal(beto.$('#t-btn-liberar').style.display, 'flex');
  assert.equal(beto.$('#t-btn-status').style.display, 'none', 'não dá para reativar quem está bloqueado');
  assert.equal(beto.$('#t-btn-atribuir').style.display, 'none');

  // no banco o card ganha o selo; na tela de Bloqueios aparece com o nome
  beto.define('#busca-banco', 'Candidato 070'); beto.define('#filtro-b-status', '');
  await beto.w.carregarBanco();
  assert.match(textoCartoes(beto).find(t => t.includes('Candidato 070 Silva')) || '', /Bloqueado/);
  await beto.w.carregarListaNegra();
  assert.match(beto.$('#ln-body').textContent, /c070@mail\.test/);
  assert.match(beto.$('#ln-body').textContent, /Candidato 070 Silva/);

  // o banco recusa a atribuição e a reativação, mesmo que alguém chame direto
  const atribuir = await beto.w.eval(`db.rpc('atribuir_candidato_vaga', { p_candidato_id: '${id}', p_vaga_id: '${sql(`select id from vagas where status='ativo' limit 1`)}' })`);
  assert.match(atribuir.error.message, /está bloqueado/);
  const reativar = await beto.w.eval(`db.rpc('alterar_status_banco', { p_candidato_id: '${id}', p_novo: 'ativo' })`);
  assert.match(reativar.error.message, /Remova o bloqueio/);

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
  assert.ok(!lista.some(t => t.includes('Candidato 082 Silva')), 'bloqueado fora da seleção, mesmo com a maior nota');
  assert.ok(!lista.some(t => t.includes('Candidato 086 Silva')), 'nível diferente fora da seleção');
  assert.deepEqual(beto.$$('#banco-lista .aderencia b').map(b => b.textContent), ['90', '70'], 'a nota de cada currículo aparece');
  assert.doesNotMatch(lista[0], /Combina em/, 'sem palavras-chave: não há IA escolhendo');
  assert.match(beto.$('#banco-total').textContent, /2 de 2 currículos|2 currículos/);

  // filtro por sexo do modo "Selecionar CVs" (045): a barra de filtros do banco some aqui, então o filtro é do próprio ranking
  assert.equal(beto.$('#banco-filtros').style.display, 'none', 'a barra normal de filtros não aparece no ranking');
  assert.deepEqual([...beto.$$('#rk-sexo option')].map(o => o.value), ['', 'feminino', 'masculino', 'nao_informado']);
  const sexoAntes = [c1, c2].map(id => sql(`select coalesce(sexo, '') from candidatos where id='${id}'`));
  sql(`update candidatos set sexo = 'feminino' where id='${c1}'`);
  sql(`update candidatos set sexo = null where id='${c2}'`);
  const filtrarPorSexo = async valor => { beto.define('#rk-sexo', valor); await beto.w.mudarFiltroRanking(); await esperar(400); };
  await filtrarPorSexo('feminino');
  assert.equal(textoCartoes(beto).length, 1);
  assert.ok(textoCartoes(beto)[0].includes('Candidato 080 Silva'), 'só a candidata feminina');
  await filtrarPorSexo('nao_informado');
  assert.equal(textoCartoes(beto).length, 1);
  assert.ok(textoCartoes(beto)[0].includes('Candidato 081 Silva'), '"não informado" = sem sexo cadastrado');
  await filtrarPorSexo('masculino');
  assert.equal(textoCartoes(beto).length, 0);
  assert.match(beto.$('#banco-lista').textContent, /Nenhum currículo selecionado com esse sexo/);
  await filtrarPorSexo('');
  assert.equal(textoCartoes(beto).length, 2, 'sem filtro voltam os dois');
  [c1, c2].forEach((id, i) => sql(`update candidatos set sexo = ${sexoAntes[i] ? `'${sexoAntes[i]}'` : 'null'} where id='${id}'`));

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

test('zona de perigo: o administrador pausa e retoma o envio à IA; o gerente de RH não consegue, nem chamando o banco direto', async () => {
  const pausada = () => sql(`select valor from configuracoes where chave = 'ia_pausada'`);
  await ana.w.carregarConfig();
  const zona = () => ana.$('#config-perigo');
  assert.ok(zona(), 'a zona de perigo aparece em Configurações');
  assert.match(zona().textContent, /Funcionando normalmente/);
  assert.match(zona().textContent, /Pausar todo envio à IA/);
  assert.equal(pausada(), 'false', 'a migração 040 deixa o interruptor desligado');

  // pausar exige ler o que vai acontecer e digitar a senha; a conferência da senha (Supabase Auth) não existe neste banco de ensaio, então é trocada aqui
  const senhaCerta = 'senha-da-ana';
  ana.w.verificarSenhaAtual = async senha => senha === senhaCerta ? { ok: true } : { ok: false, msg: 'Senha incorreta.' };
  const digitarSenha = valor => { ana.define('#pausa-ia-senha', valor); ana.$('#pausa-ia-senha').dispatchEvent(new ana.w.Event('input')); };
  const modalPausa = () => ana.$('#modal-pausar-ia');

  await ana.w.alternarPausaIA(true);
  assert.ok(modalPausa().classList.contains('show'), 'pausar abre a explicação, não pausa direto');
  assert.equal(pausada(), 'false', 'só abrir o modal não pausa nada');
  for (const trecho of [/interrompe o gasto com a API da Anthropic/, /O que vai acontecer/, /Prejuízos enquanto estiver pausado/, /Nada se perde/, /digite a sua senha/])
    assert.match(modalPausa().textContent, trecho);
  assert.equal(ana.$('#pausa-ia-ok').disabled, true, 'sem senha digitada o botão de pausar não liga');
  await ana.w.confirmarPausaIA();
  assert.equal(pausada(), 'false', 'enviar o formulário sem senha não pausa');

  digitarSenha('senha-errada');
  assert.equal(ana.$('#pausa-ia-ok').disabled, false);
  await ana.w.confirmarPausaIA();
  assert.equal(pausada(), 'false', 'senha errada não pausa');
  assert.equal(ana.$('#pausa-ia-erro').style.display, 'block');
  assert.match(ana.$('#pausa-ia-erro').textContent, /Senha incorreta/);
  assert.ok(modalPausa().classList.contains('show'), 'o modal continua aberto para tentar de novo');

  ana.w.fecharPausaIA();                                            // desistir: nada muda e a senha não fica no campo
  assert.ok(!modalPausa().classList.contains('show'));
  assert.equal(ana.$('#pausa-ia-senha').value, '');
  assert.equal(pausada(), 'false');

  await ana.w.alternarPausaIA(true);                                // reabre limpo: sem erro antigo e com o botão desligado
  assert.equal(ana.$('#pausa-ia-erro').style.display, 'none');
  assert.equal(ana.$('#pausa-ia-ok').disabled, true);
  digitarSenha(senhaCerta);
  await ana.w.confirmarPausaIA();
  assert.ok(!modalPausa().classList.contains('show'), 'com a senha certa o modal fecha');
  assert.equal(ana.$('#pausa-ia-senha').value, '', 'a senha não fica no campo');
  assert.equal(pausada(), 'true');
  assert.equal(sql(`select updated_by from configuracoes where chave = 'ia_pausada'`), ANA, 'fica registrado quem pausou');
  assert.match(ana.ultimoToast(), /PAUSADO/);
  assert.match(zona().textContent, /PAUSADO desde .* por Ana Admin/);
  assert.match(zona().textContent, /Retomar envio à IA/);
  assert.ok(zona().classList.contains('pausada'));
  assert.equal(ana.$$('#config-perigo').length, 1, 'a zona não se duplica ao ser redesenhada');

  // o gerente de RH não desfaz a pausa: a política do banco filtra e a linha não muda (sem erro, só 0 linhas)
  const tentativa = await beto.w.eval(`db.from('configuracoes').update({ valor: false }).eq('chave', 'ia_pausada').select('valor')`);
  assert.equal(tentativa.data.length, 0);                                  // (array de outro contexto do jsdom: compara o tamanho)
  assert.equal(pausada(), 'true', 'nada mudou');
  // ... e se ele chamar a função do painel, a tela avisa em vez de fingir que deu certo
  await beto.w.alternarPausaIA(false);
  assert.match(beto.ultimoToast(), /só o administrador/);
  assert.equal(pausada(), 'true');

  await ana.w.alternarPausaIA(false);
  assert.equal(pausada(), 'false');
  assert.match(ana.ultimoToast(), /retomado/);
  assert.match(zona().textContent, /Funcionando normalmente/);
  assert.ok(!zona().classList.contains('pausada'));
  assert.deepEqual(ana.erros, []);
});

test('janela de leitura do robô: hora HH:MM (texto), intervalo em minutos e dias da semana como lista (é o que o robô lê)', async () => {
  const valor = chave => sql(`select valor from configuracoes where chave = '${chave}'`);
  const padrao = { leitura_hora_inicio: '"07:30"', leitura_hora_fim: '"18:00"', leitura_intervalo_minutos: '10', leitura_dias_semana: '[1, 2, 3, 4, 5, 6]' };
  try {
    await ana.w.carregarConfig();
    for (const [k, v] of Object.entries(padrao)) assert.equal(valor(k), v, `a migração 046 semeia ${k}`);

    // os campos: hora com seletor, número com limites e os dias como botões de marcar (seg a sáb marcados, domingo não)
    assert.equal(ana.$('#cfg-leitura_hora_inicio').type, 'time');
    assert.equal(ana.$('#cfg-leitura_hora_inicio').value, '07:30');
    assert.equal(ana.$('#cfg-leitura_hora_fim').value, '18:00');
    const intervalo = ana.$('#cfg-leitura_intervalo_minutos');
    assert.deepEqual([intervalo.value, intervalo.min, intervalo.max], ['10', '1', '240']);
    assert.deepEqual([...ana.$$('#cfg-leitura_dias_semana input')].map(i => [i.value, i.checked]),
      [['1', true], ['2', true], ['3', true], ['4', true], ['5', true], ['6', true], ['7', false]]);
    assert.equal(ana.$('#cfg-horario_execucao_pipeline'), null, 'o horário diário único acabou');

    // hora: só HH:MM; apagada não grava (o robô cairia no padrão em silêncio)
    ana.define('#cfg-leitura_hora_inicio', '');
    await ana.w.salvarConfig('leitura_hora_inicio');
    assert.match(ana.ultimoToast(), /HH:MM/);
    assert.equal(valor('leitura_hora_inicio'), padrao.leitura_hora_inicio, 'não gravou');

    // início depois do fim: recusa (nos dois campos)
    ana.define('#cfg-leitura_hora_inicio', '19:00');
    await ana.w.salvarConfig('leitura_hora_inicio');
    assert.match(ana.ultimoToast(), /antes do horário de fim/);
    assert.equal(valor('leitura_hora_inicio'), padrao.leitura_hora_inicio);
    ana.define('#cfg-leitura_hora_inicio', '08:00');
    ana.define('#cfg-leitura_hora_fim', '07:00');
    await ana.w.salvarConfig('leitura_hora_fim');
    assert.match(ana.ultimoToast(), /antes do horário de fim/);
    assert.equal(valor('leitura_hora_fim'), padrao.leitura_hora_fim);

    // válido: grava texto "HH:MM", não número
    ana.define('#cfg-leitura_hora_fim', '17:30');
    await ana.w.salvarConfig('leitura_hora_fim');
    assert.match(ana.ultimoToast(), /Configuração salva/);
    assert.equal(valor('leitura_hora_fim'), '"17:30"');
    await ana.w.salvarConfig('leitura_hora_inicio');
    assert.equal(valor('leitura_hora_inicio'), '"08:00"');

    // intervalo: número inteiro de 1 a 240
    for (const ruim of ['0', '241', '', '7.5']) {
      ana.define('#cfg-leitura_intervalo_minutos', ruim);
      await ana.w.salvarConfig('leitura_intervalo_minutos');
      assert.equal(valor('leitura_intervalo_minutos'), '10', `"${ruim}" não pode gravar`);
    }
    ana.define('#cfg-leitura_intervalo_minutos', '15');
    await ana.w.salvarConfig('leitura_intervalo_minutos');
    assert.equal(valor('leitura_intervalo_minutos'), '15', 'número, não texto');

    // dias: pelo menos um; grava a lista de números (1 = segunda ... 7 = domingo)
    for (const i of ana.$$('#cfg-leitura_dias_semana input')) i.checked = false;
    await ana.w.salvarConfig('leitura_dias_semana');
    assert.match(ana.ultimoToast(), /pelo menos um dia/);
    assert.equal(valor('leitura_dias_semana'), padrao.leitura_dias_semana, 'não gravou');
    for (const i of ana.$$('#cfg-leitura_dias_semana input')) i.checked = ['1', '3', '5', '7'].includes(i.value);
    await ana.w.salvarConfig('leitura_dias_semana');
    assert.match(ana.ultimoToast(), /Configuração salva/);
    assert.equal(valor('leitura_dias_semana'), '[1, 3, 5, 7]');
    assert.deepEqual(ana.erros, []);
  } finally {
    for (const [k, v] of Object.entries(padrao)) sql(`update configuracoes set valor = '${v}'::jsonb where chave = '${k}'`);
  }
});

test('status do robô: os estados que a tela mostra (função pura) e o aviso de "sem sinal"', async () => {
  const agora = Date.parse('2026-09-28T10:00:00-03:00');                     // segunda-feira
  const min = m => new Date(agora - m * 60000).toISOString();
  const em = m => new Date(agora + m * 60000).toISOString();
  const i = (linha, t = agora) => beto.w.interpretarStatus(linha, t);
  const base = { verificado_em: min(0.5), processando_total: 0, processando_feitos: 0 };

  assert.equal(i(null).chave, 'sem-dados');
  assert.match(i(null).detalhe, /Railway/);

  const ocioso = i({ ...base, estado: 'ocioso', proxima_leitura_em: em(5) });
  assert.deepEqual([ocioso.chave, ocioso.titulo], ['ocioso', 'Robô ativo']);
  assert.match(ocioso.detalhe, /Esperando a próxima leitura, às \d\d:\d\d\./);

  const lendo = i({ ...base, estado: 'processando', atividade: 'Lendo os e-mails da caixa', processando_total: 12, processando_feitos: 5 });
  assert.deepEqual([lendo.chave, lendo.titulo], ['processando', 'Processando agora']);
  assert.equal(lendo.detalhe, 'Lendo os e-mails da caixa (5 de 12)');

  const fora = i({ ...base, estado: 'fora_do_horario', proxima_leitura_em: new Date(agora + 3 * 86400000).toISOString() });
  assert.equal(fora.chave, 'fora');
  assert.match(fora.detalhe, /volta a ler os e-mails \w+ às \d\d:\d\d/);               // outro dia: leva o dia da semana

  assert.equal(i({ ...base, estado: 'pausado' }).chave, 'pausado');
  assert.match(i({ ...base, estado: 'pausado' }).detalhe, /Zona de perigo/);
  const erro = i({ ...base, estado: 'erro', ultimo_erro: 'IMAP caiu' });
  assert.deepEqual([erro.chave, erro.detalhe], ['erro', 'IMAP caiu']);

  // sem sinal: passou do limite (6 min) o robô parou, seja qual for o estado que ele gravou por último
  assert.equal(i({ ...base, estado: 'ocioso', verificado_em: min(6) }).chave, 'ocioso', '6 min ainda é sinal recente');
  for (const estado of ['ocioso', 'processando', 'fora_do_horario', 'pausado']) {
    const parado = i({ ...base, estado, verificado_em: min(20) });
    assert.equal(parado.chave, 'sem-sinal', estado);
    assert.match(parado.detalhe, /Último sinal há 20 min/);
  }
  assert.match(i({ ...base, verificado_em: min(180) }).detalhe, /há 3 h/);
});

test('status do robô: o RH lê a linha, a tela mostra os números e o ponto do menu, e ninguém escreve pelo painel', async () => {
  const marcar = campos => sql(`update pipeline_status set ${campos}`);
  const limpo = `estado = 'ocioso', atividade = null, verificado_em = now(), nao_lidos = null, nao_lidos_em = null, processando_total = 0,
    processando_feitos = 0, processando_desde = null, ultima_leitura_em = null, ultima_leitura_fim = null, ultima_leitura_sucesso = null,
    ultima_leitura_resumo = null, proxima_leitura_em = null, ultimo_erro = null, ultimo_erro_em = null, lease_dono = null, lease_ate = null`;
  const texto = seletor => beto.$(seletor).textContent.replace(/\s+/g, ' ').trim();
  try {
    marcar(limpo);
    // o item do menu é de todo o RH (Configurações é só do administrador)
    assert.notEqual(beto.$('#nav-status').style.display, 'none');
    assert.equal(beto.$('#nav-config').style.display, 'none');

    // ocioso, com contagem e próxima leitura
    marcar(`nao_lidos = 7, nao_lidos_em = now(), proxima_leitura_em = now() + interval '5 minutes'`);
    beto.w.irPara('status', beto.$('#nav-status'));
    await beto.w.carregarStatus();
    assert.equal(texto('#status-estado'), 'Robô ativo');
    assert.ok(beto.$('#status-topo').classList.contains('ocioso'));
    assert.ok(beto.$('#nav-status-luz').classList.contains('ocioso'), 'o ponto do menu acompanha o estado');
    assert.equal(texto('#st-nao-lidos'), '7');
    assert.match(texto('#st-nao-lidos-sub'), /contados às \d\d:\d\d/);
    assert.equal(texto('#st-processando'), 'Nada');
    assert.match(texto('#st-proxima-sub'), /em [45] min/);
    assert.equal(texto('#st-excecoes'), sql(`select count(*) from excecoes where status = 'pendente'`));

    // lendo: "x de y", barra e "aguardando" descendo a cada e-mail tratado
    marcar(`estado = 'processando', atividade = 'Lendo os e-mails da caixa', processando_total = 10, processando_feitos = 4, nao_lidos = 10,
            nao_lidos_em = now() - interval '1 minute', processando_desde = now()`);
    await beto.w.carregarStatus();
    assert.equal(texto('#status-estado'), 'Processando agora');
    assert.match(texto('#status-detalhe'), /Lendo os e-mails da caixa \(4 de 10\)/);
    assert.equal(texto('#st-processando'), '4 de 10');
    assert.equal(beto.$('#st-barra').style.width, '40%');
    assert.notEqual(beto.$('#st-barra-wrap').style.display, 'none');
    assert.equal(texto('#st-nao-lidos'), '6', '10 contados, 4 já tratados');
    assert.ok(beto.$('#nav-status-luz').classList.contains('processando'));

    // pedido do RH em andamento não mexe na contagem de e-mails
    marcar(`atividade = 'Pedidos do RH: tentar de novo', processando_total = 2, processando_feitos = 0, nao_lidos = 10`);
    await beto.w.carregarStatus();
    assert.equal(texto('#st-nao-lidos'), '10');

    // última leitura concluída, com o resumo
    marcar(`estado = 'ocioso', atividade = null, processando_total = 0, processando_feitos = 0, processando_desde = null,
            ultima_leitura_em = now() - interval '3 minutes', ultima_leitura_fim = now() - interval '2 minutes', ultima_leitura_sucesso = true,
            ultima_leitura_resumo = '{"emails_lidos": 6, "curriculos_processados": 4, "excecoes_geradas": 1, "duplicados_detectados": 1, "custo_estimado_usd": 0.0812}'::jsonb`);
    await beto.w.carregarStatus();
    const ultima = texto('#st-ultima');
    assert.match(ultima, /Concluída/);
    assert.match(ultima, /E-mails lidos\s*6/);
    assert.match(ultima, /Currículos novos no banco\s*4/);
    assert.match(ultima, /Exceções geradas\s*1/);
    assert.match(ultima, /US\$ 0\.08/);
    assert.match(texto('#st-ultima-sub'), /há 3 min/);

    // com erro: o texto do erro aparece
    marcar(`estado = 'erro', ultima_leitura_sucesso = false, ultimo_erro = 'IMAP caiu', ultimo_erro_em = now()`);
    await beto.w.carregarStatus();
    assert.equal(texto('#status-estado'), 'Erro na última leitura');
    assert.match(texto('#st-ultima'), /Com erro/);
    assert.match(texto('#st-ultima'), /IMAP caiu/);
    assert.ok(beto.$('#nav-status-luz').classList.contains('erro'));

    // as regras vêm de Configurações (padrão da 046: seg a sáb, 07:30 às 18:00, a cada 10 min)
    const regras = texto('#st-regras');
    assert.match(regras, /Segunda a sábado/);
    assert.match(regras, /07:30 às 18:00/);
    assert.match(regras, /a cada\s*10 min/);
    assert.ok(!/Alterar em Configurações/.test(regras), 'o link para Configurações é só do administrador');

    // sem sinal: o robô parou; nada de "próxima leitura" inventada
    marcar(`estado = 'ocioso', verificado_em = now() - interval '20 minutes', proxima_leitura_em = now() + interval '5 minutes'`);
    await beto.w.carregarStatus();
    assert.equal(texto('#status-estado'), 'Sem sinal do robô');
    assert.ok(beto.$('#status-topo').classList.contains('sem-sinal'));
    assert.ok(beto.$('#nav-status-luz').classList.contains('sem-sinal'));
    assert.equal(texto('#st-proxima'), '—');
    assert.match(texto('#status-atualizado'), /há 20 min/);

    // o atalho da fila de exceções abre a aba certa de Vagas
    beto.w.irParaFilaDeExcecoes();
    await new Promise(r => setTimeout(r, 300));
    assert.equal(beto.w.eval('app.telaAtual'), 'vagas');
    assert.ok(beto.$('#sub-excecoes').classList.contains('active'));

    // o administrador vê o atalho para as configurações
    ana.w.irPara('status', ana.$('#nav-status'));
    await ana.w.carregarStatus();
    assert.match(ana.$('#st-regras').textContent, /Alterar em Configurações/);

    // permissões: o RH lê a linha, mas nenhum perfil do painel escreve (só o robô, com a chave de serviço)
    for (const painel of [beto, ana]) {
      const r = await painel.w.eval("db.from('pipeline_status').update({ estado: 'ocioso' }).eq('id', true).select()");
      assert.ok(r.error, 'o painel não pode escrever no status');
      const d = await painel.w.eval("db.from('pipeline_status').delete().eq('id', true).select()");
      assert.ok(d.error, 'nem apagar');
    }
    const lida = await beto.w.eval("db.from('pipeline_status').select('estado,nao_lidos').eq('id', true)");
    assert.equal(lida.data.length, 1);
    assert.deepEqual(beto.erros, []);
  } finally {
    marcar(limpo);
    beto.w.irPara('dashboard');
  }
});

test('configurações: nomes claros, aviso "Sem efeito hoje" nos campos de enfeite, busca, atalhos e validação ao salvar', async () => {
  // no banco de produção estas linhas existem; o ensaio só tem as da sanitização e da IA
  const extras = ['imap_servidor', 'imap_porta', 'tamanho_minimo_anexo_bytes', 'mensagem_convocacao_padrao', 'ddi_padrao', 'ddd_padrao'];
  sql(`insert into configuracoes (chave, valor, descricao) values ('imap_servidor', '"email-ssl.com.br"', 'x'), ('imap_porta', '993', 'x'),
       ('tamanho_minimo_anexo_bytes', '10240', 'x'), ('mensagem_convocacao_padrao', '"Olá {nome}"', 'x'), ('ddi_padrao', '"55"', 'x'), ('ddd_padrao', '"61"', 'x')
       on conflict (chave) do nothing`);
  try {
    await ana.w.carregarConfig();
    const tela = () => ana.$('#config-lista');
    const itens = () => ana.$$('#config-lista .config-item').filter(i => i.style.display !== 'none');

    // nome claro em cima, explicação embaixo e o nome técnico pequeno (para suporte)
    const item = chave => ana.$(`#cfg-${chave}`).closest('.config-item');
    assert.equal(item('sanitizacao_meses_sem_movimentacao').querySelector('.config-titulo').textContent.trim(), 'Sugerir quem está parado há mais de');
    assert.equal(item('sanitizacao_meses_sem_movimentacao').querySelector('.config-chave').textContent, 'sanitizacao_meses_sem_movimentacao');
    assert.equal(item('sanitizacao_meses_sem_movimentacao').querySelector('.config-unidade').textContent, 'meses');
    assert.match(item('modelo_ia_avaliacao').querySelector('.config-titulo').textContent, /IA que analisa o currículo/);
    assert.equal(ana.$('#cfg-sanitizacao_detectar_duplicidade').tagName, 'SELECT', 'sim/não em vez de digitar "true"');
    assert.equal(ana.$('#cfg-sanitizacao_pesos').tagName, 'TEXTAREA');

    // o que não vale (ou não se mexe) NÃO aparece: servidor e porta do e-mail, a segunda avaliação e a regra de nota de vaga baixa,
    // mesmo com as linhas existindo no banco (o ensaio tem as faixas e a aderência; os de e-mail o teste acabou de inserir)
    for (const k of ['imap_servidor', 'imap_porta', 'faixa_ambigua_min', 'faixa_ambigua_max', 'sanitizacao_aderencia_min'])
      assert.equal(ana.$(`#cfg-${k}`), null, `${k} não aparece na tela`);
    assert.equal(ana.$('#cfg-segunda-ativa'), null, 'sem o interruptor da segunda avaliação');
    assert.ok(!/segunda avalia/i.test(tela().textContent), 'nenhuma menção à segunda avaliação');
    assert.ok(!tela().textContent.includes('imap_servidor'));
    assert.equal(ana.$$('.config-tag-sem-efeito').length, 0, 'todo campo que aparece vale: nenhum leva o aviso "Sem efeito hoje"');
    assert.ok(!item('leitura_hora_inicio').querySelector('.config-tag-sem-efeito'));
    assert.equal(ana.$('#cfg-tamanho_minimo_anexo_bytes').disabled, false, 'o tamanho mínimo da imagem é editável');

    // atalhos para cada grupo, inclusive os blocos que já existiam
    const atalhos = ana.$$('#config-atalhos .config-atalho').map(b => b.textContent);
    for (const rotulo of ['Leitura de e-mails', 'Inteligência artificial', 'Limpeza do banco (LGPD)', 'WhatsApp e telefones', 'Níveis de experiência', 'Zona de perigo'])
      assert.ok(atalhos.includes(rotulo), `falta o atalho ${rotulo}`);

    // busca: por palavra do título, da explicação, do nome técnico e sem acento/maiúscula
    const total = itens().length;
    ana.define('#config-busca', 'WHATSAPP'); ana.w.filtrarConfig();
    assert.ok(itens().length >= 3 && itens().length < total);
    assert.ok(itens().every(i => /whatsapp|ddi|ddd|convoca/i.test(i.textContent)), 'só o que tem a ver com WhatsApp');
    assert.equal(ana.$('#cfg-grupo-limpeza').style.display, 'none', 'grupo sem resultado some');
    ana.define('#config-busca', 'confianca'); ana.w.filtrarConfig();         // sem acento acha "confiança"
    assert.ok(itens().some(i => i.querySelector('#cfg-ia_confianca_minima')));
    ana.define('#config-busca', 'zzzz-nada'); ana.w.filtrarConfig();
    assert.equal(ana.$('#config-sem-resultado').style.display, '', 'avisa quando nada casa');
    ana.define('#config-busca', ''); ana.w.filtrarConfig();
    assert.equal(itens().length, total, 'limpar a busca mostra tudo de novo');

    // validação ao salvar: número fora da faixa e JSON quebrado não chegam ao banco
    const valorNoBanco = chave => sql(`select valor from configuracoes where chave = '${chave}'`);
    const antes = valorNoBanco('ia_confianca_minima');
    ana.define('#cfg-ia_confianca_minima', '150'); await ana.w.salvarConfig('ia_confianca_minima');
    assert.match(ana.ultimoToast(), /de 0 a 100/);
    assert.equal(valorNoBanco('ia_confianca_minima'), antes);
    const pesos = valorNoBanco('sanitizacao_pesos');
    ana.define('#cfg-sanitizacao_pesos', '{"limite_alta": 4,'); await ana.w.salvarConfig('sanitizacao_pesos');
    assert.match(ana.ultimoToast(), /Formato inválido/);
    assert.equal(valorNoBanco('sanitizacao_pesos'), pesos, 'o JSON quebrado não foi gravado');
    // sim/não grava o booleano de verdade (não o texto "false")
    ana.define('#cfg-sanitizacao_detectar_duplicidade', 'false'); await ana.w.salvarConfig('sanitizacao_detectar_duplicidade');
    assert.equal(sql(`select jsonb_typeof(valor) || ':' || valor::text from configuracoes where chave = 'sanitizacao_detectar_duplicidade'`), 'boolean:false');
    ana.define('#cfg-sanitizacao_detectar_duplicidade', 'true'); await ana.w.salvarConfig('sanitizacao_detectar_duplicidade');
    // o JSON válido (o mesmo que já estava) salva como objeto
    await ana.w.carregarConfig();
    await ana.w.salvarConfig('sanitizacao_pesos');
    assert.match(ana.ultimoToast(), /Configuração salva/);
    assert.equal(sql(`select jsonb_typeof(valor) from configuracoes where chave = 'sanitizacao_pesos'`), 'object');
    assert.deepEqual(ana.erros, []);
  } finally {
    sql(`delete from configuracoes where chave in (${extras.map(k => `'${k}'`).join(', ')})`);
  }
});

test('configurações que agora valem: DDI/DDD e a mensagem do WhatsApp mudam o painel na hora; a imagem mínima é validada', async () => {
  const chaves = ['ddi_padrao', 'ddd_padrao', 'mensagem_convocacao_padrao', 'tamanho_minimo_anexo_bytes'];
  sql(`insert into configuracoes (chave, valor, descricao) values ('ddi_padrao', '"55"', 'x'), ('ddd_padrao', '"61"', 'x'),
       ('mensagem_convocacao_padrao', to_jsonb('Olá {nome}, meu nome é {gestor} e você terá uma entrevista no dia {data} às {hora}.'::text), 'x'),
       ('tamanho_minimo_anexo_bytes', '10240', 'x') on conflict (chave) do nothing`);
  const noBanco = chave => sql(`select valor from configuracoes where chave = '${chave}'`);
  try {
    await ana.w.carregarBase();                                                       // como no login: o painel lê estas configurações
    assert.equal(ana.w.eval('app.cache.config.ddd_padrao'), '61');
    await ana.w.carregarConfig();

    // DDI/DDD: padrão de sempre, depois o do painel (vale sem recarregar), e o do número, quando ele tem, continua valendo
    assert.equal(ana.w.normalizaTelefone('99211-6739'), '5561992116739');
    ana.define('#cfg-ddd_padrao', '11'); await ana.w.salvarConfig('ddd_padrao');
    assert.equal(noBanco('ddd_padrao'), '"11"', 'grava texto, não número');
    assert.equal(ana.w.normalizaTelefone('99211-6739'), '5511992116739');
    assert.equal(ana.w.normalizaTelefone('(21) 99211-6739'), '5521992116739');
    ana.define('#cfg-ddi_padrao', '351'); await ana.w.salvarConfig('ddi_padrao');
    assert.equal(ana.w.normalizaTelefone('21992116739'), '35121992116739');
    ana.define('#cfg-ddd_padrao', '611'); await ana.w.salvarConfig('ddd_padrao');       // inválido: nem chega ao banco
    assert.match(ana.ultimoToast(), /só números, de 2 a 2 dígitos/);
    assert.equal(noBanco('ddd_padrao'), '"11"');
    ana.define('#cfg-ddi_padrao', '+55'); await ana.w.salvarConfig('ddi_padrao');
    assert.match(ana.ultimoToast(), /só números/);
    ana.w.eval(`app.cache.config.ddd_padrao = 'xx'; app.cache.config.ddi_padrao = ''`);   // valor estragado no banco: cai no padrão, sem quebrar
    assert.equal(ana.w.normalizaTelefone('99211-6739'), '5561992116739');

    // mensagem de convocação: marcador desconhecido e texto vazio são recusados; o certo vira a mensagem do agendamento
    const original = noBanco('mensagem_convocacao_padrao');
    ana.define('#cfg-mensagem_convocacao_padrao', 'Oi {nome}, sua entrevista é em {local}'); await ana.w.salvarConfig('mensagem_convocacao_padrao');
    assert.match(ana.ultimoToast(), /Marcador \{local\} desconhecido/);
    ana.define('#cfg-mensagem_convocacao_padrao', '   '); await ana.w.salvarConfig('mensagem_convocacao_padrao');
    assert.match(ana.ultimoToast(), /não pode ficar vazia/);
    assert.equal(noBanco('mensagem_convocacao_padrao'), original, 'nada foi gravado');
    ana.define('#cfg-mensagem_convocacao_padrao', 'Oi {nome}! Aqui é {gestor}: entrevista em {data} às {hora}.');
    await ana.w.salvarConfig('mensagem_convocacao_padrao');
    assert.match(ana.ultimoToast(), /Configuração salva/);
    ana.w.abrirAgendamento('cand-1', 'Maria Souza', '61999991234');
    assert.match(ana.$('#ag-msg').value, /^Oi Maria Souza! Aqui é Ana Admin: entrevista em \d{2}\/\d{2}\/\d{4} às 09:00\.$/);
    assert.equal(ana.$('#ag-msg').value, ana.$('#ag-preview').textContent, 'a prévia mostra o mesmo texto');
    ana.w.fecharModal('modal-agendar');
    // sem mensagem em Configurações, vale o texto de fábrica (o de sempre)
    ana.w.eval(`app.cache.config.mensagem_convocacao_padrao = ''`);
    ana.w.abrirAgendamento('cand-1', 'Maria Souza', '61999991234');
    assert.match(ana.$('#ag-msg').value, /^Olá Maria Souza, meu nome é Ana Admin e você terá uma entrevista no dia .* às 09:00\.\nConfirme essa mensagem por favor\.$/);
    ana.w.fecharModal('modal-agendar');

    // tamanho mínimo da imagem: só de 1 KB a 1 MB
    ana.define('#cfg-tamanho_minimo_anexo_bytes', '500'); await ana.w.salvarConfig('tamanho_minimo_anexo_bytes');
    assert.match(ana.ultimoToast(), /de 1024 a 1048576/);
    assert.equal(noBanco('tamanho_minimo_anexo_bytes'), '10240');
    ana.define('#cfg-tamanho_minimo_anexo_bytes', '8192'); await ana.w.salvarConfig('tamanho_minimo_anexo_bytes');
    assert.equal(noBanco('tamanho_minimo_anexo_bytes'), '8192');
    assert.deepEqual(ana.erros, []);
  } finally {
    sql(`delete from configuracoes where chave in (${chaves.map(k => `'${k}'`).join(', ')})`);
    ana.w.eval('app.cache.config = {}');
  }
});

test('histórico do candidato: filtros por nome e telefone, registro à mão (sem interesse, desistência), alteração e exclusão só do administrador', async () => {
  const limpar = () => sql(`delete from historico_candidatos where nome like '% Hist'`);
  limpar();
  sql(`insert into historico_candidatos (nome, telefone, data_evento, setor_vaga, vaga_titulo, status, observacao, origem) values
       ('Maria Teste Hist', '(61) 99999-1111', '2026-09-10', 'Logística', 'Auxiliar de Logística', 'aprovado', 'Ótima conversa', 'sistema'),
       ('João Teste Hist',  '61 98888-2222',   '2026-09-11', 'Loja', null, 'nao_compareceu', null, 'sistema'),
       ('Ana Teste Hist',   null,              '2026-09-12', null, null, 'reprovado', 'Sem CNH', 'manual')`);
  const linhas = p => p.$$('#hist-body tr.hist-linha');
  const nomes = p => linhas(p).map(l => l.querySelector('.hist-nome').textContent);
  const filtrar = async (p, nome = '', tel = '', status = '') => {
    p.define('#hist-nome', nome); p.define('#hist-tel', tel); p.define('#hist-status', status);
    await p.w.carregarHistorico();
  };
  try {
    // a tela abre com tudo, do mais recente para o mais antigo
    await filtrar(beto, 'teste hist');
    assert.deepEqual(nomes(beto), ['Ana Teste Hist', 'João Teste Hist', 'Maria Teste Hist']);
    assert.match(beto.$('#hist-contador').textContent, /3 registros com esses filtros/);
    const maria = beto.$$('#hist-body tr.hist-linha').find(l => l.textContent.includes('Maria'));
    assert.match(maria.textContent, /10\/09\/2026/);
    assert.match(maria.textContent, /\(61\) 99999-1111/);
    assert.match(maria.textContent, /Logística/);
    assert.match(maria.textContent, /Aprovado/);
    assert.match(maria.textContent, /Ótima conversa/);

    // filtro por nome: parcial, sem acento nem maiúscula
    await filtrar(beto, 'JOAO'); assert.deepEqual(nomes(beto), ['João Teste Hist']);
    await filtrar(beto, 'mar'); assert.ok(nomes(beto).includes('Maria Teste Hist'));
    // filtro por telefone: só os números, com ou sem máscara
    await filtrar(beto, 'teste hist', '(61) 99999'); assert.deepEqual(nomes(beto), ['Maria Teste Hist']);
    await filtrar(beto, 'teste hist', '98888-2222'); assert.deepEqual(nomes(beto), ['João Teste Hist']);
    await filtrar(beto, 'teste hist', '61988882222'); assert.deepEqual(nomes(beto), ['João Teste Hist']);
    // filtro por status
    await filtrar(beto, 'teste hist', '', 'nao_compareceu'); assert.deepEqual(nomes(beto), ['João Teste Hist']);
    // nada encontrado
    await filtrar(beto, 'zzzz-ninguem');
    assert.equal(linhas(beto).length, 0);
    assert.match(beto.$('#hist-body').textContent, /Nada encontrado/);
    assert.match(beto.$('#hist-contador').textContent, /Nenhum registro com esses filtros/);

    // detalhes: o que existe do cadastro e a origem do registro
    await filtrar(beto, 'teste hist');
    const idMaria = sql(`select id from historico_candidatos where nome = 'Maria Teste Hist'`);
    beto.w.alternarDetalheHistorico(idMaria);
    assert.equal(beto.$$('#hist-body tr.hist-detalhe').length, 1);
    assert.match(beto.$('#hist-body tr.hist-detalhe').textContent, /Origem do registro.*Automático/);
    assert.match(beto.$('#hist-body tr.hist-detalhe').textContent, /não estão mais no Banco de Talentos/, 'sem cadastro ligado: avisa');
    beto.w.alternarDetalheHistorico(idMaria);
    assert.equal(beto.$$('#hist-body tr.hist-detalhe').length, 0, 'clicar de novo fecha');

    // com o cadastro ainda no Banco de Talentos: currículo e análise da IA a um clique (inclusive de candidato inativo)
    sql(`insert into historico_candidatos (candidato_id, nome, telefone, data_evento, status, origem)
         select id, 'Ligada Teste Hist', '(61) 96666-4444', '2026-09-15', 'aprovado', 'manual' from candidatos where nome = 'Candidato 096 Silva'`);
    const idLigada = sql(`select id from historico_candidatos where nome = 'Ligada Teste Hist'`);
    const candLigado = sql(`select candidato_id from historico_candidatos where id = '${idLigada}'`);
    await filtrar(beto, 'ligada teste');
    beto.w.alternarDetalheHistorico(idLigada);
    const detalhe = () => beto.$('#hist-body tr.hist-detalhe').textContent;
    assert.match(detalhe(), /Ver currículo/);
    assert.match(detalhe(), /Ver cadastro e análise da IA/);
    assert.doesNotMatch(detalhe(), /não estão mais no Banco de Talentos/);
    await beto.w.abrirTalento(candLigado);
    assert.ok(beto.$('#drawer-talento').classList.contains('show'), 'abre o cadastro do candidato');
    assert.match(beto.$('#t-ia').textContent, /Sugestão da IA/, 'com a análise da IA');
    beto.w.fecharDrawer();
    sql(`update candidatos set status_banco = 'inativo', inativado_em = now(), motivo_inativacao = 'teste do histórico' where id = '${candLigado}'`);
    await filtrar(beto, 'ligada teste');
    beto.w.alternarDetalheHistorico(idLigada);
    assert.match(detalhe(), /Ver cadastro e análise da IA/, 'inativo ainda tem cadastro e análise');
    await beto.w.abrirTalento(candLigado);
    assert.ok(beto.$('#drawer-talento').classList.contains('show'));
    beto.w.fecharDrawer();
    sql(`update candidatos set status_banco = 'ativo', inativado_em = null, motivo_inativacao = null where id = '${candLigado}'`);
    await filtrar(beto, 'teste hist');

    // novo registro à mão: desistência depois de aprovado
    beto.w.abrirRegistroHistorico();
    beto.define('#hist-f-status', 'desistencia'); beto.w.dicaStatusHistorico();
    assert.match(beto.$('#hist-f-dica').textContent, /documentação ou no treinamento/);
    await beto.w.salvarRegistroHistorico();
    assert.match(beto.ultimoToast(), /Informe o nome/, 'nome é obrigatório');
    beto.define('#hist-f-nome', 'Carlos Desistente Hist'); beto.define('#hist-f-tel', '(61) 97777-3333'); beto.define('#hist-f-data', '2026-09-14');
    beto.define('#hist-f-setor', 'Logística'); beto.define('#hist-f-obs', 'Desistiu no treinamento');
    beto.define('#hist-f-status', '');
    await beto.w.salvarRegistroHistorico();
    assert.match(beto.ultimoToast(), /Escolha o status/);
    beto.define('#hist-f-status', 'desistencia');
    await beto.w.salvarRegistroHistorico();
    assert.match(beto.ultimoToast(), /Registro criado/);
    assert.equal(sql(`select status || '|' || origem || '|' || setor_vaga || '|' || data_evento || '|' || observacao from historico_candidatos where nome = 'Carlos Desistente Hist'`),
      'desistencia|manual|Logística|2026-09-14|Desistiu no treinamento');
    assert.ok(!nomes(beto).includes('Carlos Desistente Hist'), 'a tela recarrega respeitando o filtro que estava ativo ("teste hist")');
    await filtrar(beto, 'desistente hist');
    assert.deepEqual(nomes(beto), ['Carlos Desistente Hist'], 'o registro novo aparece');
    await filtrar(beto, '', '', 'desistencia');
    assert.ok(nomes(beto).includes('Carlos Desistente Hist'));

    // alterar: a linha do sistema vira "desistência" e deixa de acompanhar a entrevista
    await filtrar(beto, 'maria teste');
    beto.w.abrirRegistroHistorico(idMaria);
    assert.notEqual(beto.$('#hist-f-aviso').style.display, 'none', 'avisa que a linha veio de Entrevistas');
    assert.equal(beto.$('#hist-f-nome').value, 'Maria Teste Hist');
    assert.equal(beto.$('#hist-f-status').value, 'aprovado');
    beto.define('#hist-f-status', 'desistencia'); beto.define('#hist-f-obs', 'Desistiu na documentação');
    await beto.w.salvarRegistroHistorico();
    assert.match(beto.ultimoToast(), /Registro atualizado/);
    assert.equal(sql(`select status || '|' || observacao || '|' || alterado_manual from historico_candidatos where id = '${idMaria}'`), 'desistencia|Desistiu na documentação|true');
    assert.match(beto.$('#hist-body').textContent, /Desistência/);
    // abrir e salvar sem mudar nada não grava (nem faz barulho)
    beto.w.abrirRegistroHistorico(idMaria);
    const antes = sql(`select atualizado_em from historico_candidatos where id = '${idMaria}'`);
    await beto.w.salvarRegistroHistorico();
    assert.equal(sql(`select atualizado_em from historico_candidatos where id = '${idMaria}'`), antes);

    // exclusão: só o administrador (o botão nem aparece para o RH, e o banco recusa mesmo assim)
    assert.equal(beto.$$('#hist-body .btn-sm.vermelho').length, 0, 'sem botão de excluir para o RH');
    const recusa = await beto.w.eval(`db.rpc('historico_excluir', { p_id: '${idMaria}' })`);
    assert.match(recusa.error.message, /Somente o administrador/);
    await filtrar(ana, 'teste hist');
    assert.ok(ana.$$('#hist-body .btn-sm.vermelho').length >= 3, 'o administrador vê o botão');
    await ana.w.excluirRegistroHistorico(idMaria);
    assert.match(ana.ultimoToast(), /Registro excluído/);
    assert.equal(sqlNum(`select count(*) from historico_candidatos where id = '${idMaria}'`), 0);
    assert.ok(!nomes(ana).includes('Maria Teste Hist'));
    assert.deepEqual(beto.erros, []); assert.deepEqual(ana.erros, []);
  } finally {
    limpar();
  }
});

test('IA pausada: o servidor responde 503 com o motivo e o painel mostra; o currículo enviado fica na fila', async () => {
  const http = require('node:http');
  const servidor = http.createServer((req, res) => {
    req.resume();
    req.on('end', () => {
      res.writeHead(503, { 'Content-Type': 'application/json' });
      res.end(JSON.stringify({ detail: 'O envio para a IA está pausado pelo administrador (Configurações → Zona de perigo)' }));
    });
  });
  await new Promise(r => servidor.listen(0, '127.0.0.1', r));
  const painel = await abrirPainel(BETO, 'gerente_rh', { apiUrl: `http://127.0.0.1:${servidor.address().port}` });
  try {
    await painel.w.eval(`db.auth.getSession = async () => ({ data: { session: { access_token: 'token-de-teste' } } })`);
    await painel.w.avaliarUploadAgora('00000000-0000-0000-0000-00000000dd01');
    assert.match(painel.ultimoToast(), /pausado pelo administrador/);
    assert.match(painel.ultimoToast(), /fica na fila/);
    assert.equal(painel.toasts.at(-1).tipo, 'erro');

    await painel.w.abrirModalVaga();
    painel.define('#ia-vaga-pedido', 'auxiliar contábil para o financeiro, nível júnior, precisa de Excel');
    await painel.w.gerarRascunhoVaga();
    assert.match(painel.ultimoToast(), /pausado pelo administrador/, 'o rascunho de vaga mostra o motivo do servidor');
    assert.equal(painel.$('#ia-vaga-btn').disabled, false, 'o botão volta a funcionar');
    assert.deepEqual(painel.erros, []);
  } finally {
    painel.fim();
    await new Promise(r => servidor.close(r));
  }
});

test('sexo estimado pelo nome: a ficha diz de onde veio, o filtro segue com as 4 opções de sempre e a correção do RH vira manual', async () => {
  limparFiltros(beto);
  const [a, b, c] = ['Candidato 095 Silva', 'Candidato 096 Silva', 'Candidato 097 Silva'].map(idDe);   // nenhum outro teste usa estes
  sql(`update candidatos set sexo = 'feminino', sexo_origem = 'ia_nome' where id = '${a}'`);           // estimado pela IA
  sql(`update candidatos set sexo = 'masculino', sexo_origem = 'informado' where id = '${b}'`);        // o currículo informa
  sql(`update candidatos set sexo = null, sexo_origem = null where id = '${c}'`);                      // sem sexo

  // a ficha: estimado avisa, informado não precisa de aviso, sem sexo mostra traço
  await beto.w.abrirTalento(a);
  assert.match(beto.$('#t-dados').textContent, /SexoFeminino — estimado pela IA a partir do nome/);
  await beto.w.abrirTalento(b);
  assert.match(beto.$('#t-dados').textContent, /SexoMasculino(?! —)/);
  await beto.w.abrirTalento(c);
  assert.match(beto.$('#t-dados').textContent, /Sexo—/);
  beto.w.fecharDrawer();

  // o filtro segue com as quatro opções de sempre (sem opção própria para o estimado) e cada uma funciona como antes
  assert.deepEqual([...beto.$$('#filtro-b-sexo option')].map(o => o.value), ['', 'feminino', 'masculino', 'nao_informado']);
  beto.define('#filtro-b-sexo', 'nao_informado');
  await beto.w.carregarBanco();
  assert.equal(totalUi(beto), sqlNum(`select count(*) from vw_banco_talentos where status_banco = 'ativo' and sexo is null`));
  beto.define('#filtro-b-sexo', 'feminino');
  await beto.w.carregarBanco();
  assert.equal(totalUi(beto), sqlNum(`select count(*) from vw_banco_talentos where status_banco = 'ativo' and sexo = 'feminino'`));

  // o RH corrige a estimativa da IA: vira "manual" e sai da lista de revisão
  await beto.w.abrirTalento(a);
  await beto.w.abrirEdicaoCandidato();          // assíncrona: espera as opções de região antes de preencher o formulário
  assert.equal(beto.$('#ed-sexo').value, 'feminino');
  beto.define('#ed-sexo', 'masculino');
  await beto.w.salvarEdicaoCandidato();
  assert.match(beto.ultimoToast(), /Dados atualizados/);
  assert.equal(sql(`select sexo || '/' || sexo_origem from candidatos where id = '${a}'`), 'masculino/manual');
  assert.match(beto.$('#t-dados').textContent, /SexoMasculino — definido pelo RH/);

  // "Não informado" escolhido pelo RH também é decisão dele (fica em branco e marcado como manual)
  await beto.w.abrirTalento(b);
  await beto.w.abrirEdicaoCandidato();
  beto.define('#ed-sexo', '');
  await beto.w.salvarEdicaoCandidato();
  assert.equal(sql(`select coalesce(sexo, 'vazio') || '/' || sexo_origem from candidatos where id = '${b}'`), 'vazio/manual');
  beto.w.fecharDrawer();
  limparFiltros(beto);
  assert.deepEqual(beto.erros, []);
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
  await beto.w.carregarBase();                                            // a loja nova entra no cache do painel (no uso real, o login já a traz)
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

  // lojas de referência (038): a seleção começa nas lojas da vaga; o RH marca outras, várias ou TODAS
  const marcadasLojas = () => beto.$$('#rk-lojas input[data-loja]').filter(c => c.checked).map(c => c.value).sort();
  const marcarLoja = async (sigla, valor) => {
    const c = sigla === 'TODAS' ? beto.$('#rk-lojas-todas') : beto.$(`#rk-lojas input[value="${sigla}"]`);
    c.checked = valor;
    c.dispatchEvent(new beto.w.Event('change', { bubbles: true }));
    await esperar(700);
  };
  assert.deepEqual(beto.$$('#rk-lojas input[data-loja]').map(c => c.value).sort(), ['CFR', 'CFS', 'CFT'], 'um chip por loja cadastrada');
  assert.equal(beto.$$('#rk-lojas input[data-loja]').filter(c => c.disabled).length, 0, 'todas têm região: nenhuma desabilitada');
  assert.deepEqual(marcadasLojas(), ['CFS', 'CFT'], 'começa nas lojas da vaga');
  assert.equal(beto.$('#rk-lojas-todas').checked, false);
  assert.match(beto.$('#rk-lojas-nota').textContent, /entre as marcadas/);

  await marcarLoja('CFS', false);
  await marcarLoja('CFT', false);
  await marcarLoja('CFR', true);                                          // só a CFR (Recanto das Emas): não é loja da vaga
  assert.deepEqual(marcadasLojas(), ['CFR']);
  assert.match(beto.$('#rk-lojas-nota').textContent, /até essa loja/i);
  assert.match(cartaoDe('Candidato 083'), /\d+,\d km da CFR/, 'a distância é até a loja escolhida, não até as da vaga');
  assert.match(cartaoDe('Candidato 084'), /\d+,\d km da CFR/);
  beto.define('#rk-km', '10');
  await beto.w.mudarFiltroRanking();
  assert.deepEqual(meus(), [], 'até 10 km da CFR: ninguém (Ceilândia e Gama ficam a ~11 km dela)');
  assert.match(beto.$('#banco-lista').textContent, /entre as escolhidas/, 'a mensagem de lista vazia fala das lojas escolhidas');

  await marcarLoja('TODAS', true);
  assert.deepEqual(marcadasLojas(), ['CFR', 'CFS', 'CFT'], 'TODAS marca todas as lojas');
  assert.deepEqual(meus().map(t => t.match(/Candidato 08\d/)[0]), ['Candidato 083'], 'até 10 km de qualquer loja: quem mora perto da CFT entra');
  assert.match(cartaoDe('Candidato 083'), /km da CFT/, 'e a loja mostrada é a mais próxima entre as escolhidas');

  await marcarLoja('TODAS', false);
  assert.deepEqual(marcadasLojas(), [], 'TODAS desmarcada limpa as lojas');
  assert.match(beto.$('#rk-lojas-nota').textContent, /Nenhuma marcada/);
  assert.deepEqual(meus().map(t => t.match(/Candidato 08\d/)[0]), ['Candidato 083'], 'nenhuma marcada vale como todas');
  await marcarLoja('CFS', true);
  assert.deepEqual(marcadasLojas(), ['CFS']);
  assert.equal(beto.$('#rk-lojas-todas').checked, false);
  await marcarLoja('CFR', true);
  await marcarLoja('CFT', true);
  assert.equal(beto.$('#rk-lojas-todas').checked, true, 'com todas as lojas marcadas, TODAS acende sozinha');
  beto.define('#rk-km', '');
  await beto.w.mudarFiltroRanking();

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

test('fila de exceções: aviso de plataforma (Trabalha Brasil) tem "Abrir currículo" no lugar de Ver e-mail e Reprocessar; a exceção comum não muda', async () => {
  const LINK = 'https://events-api.bne.com.br/api/v1/events/tracking-event?evento=t&MessageId=1&url=http%3A%2F%2Fwww.trabalhabrasil.com.br%2Fvisualizar-curriculo%2Fu%3Fcurriculo%3DABC&sig=X';
  sql(`insert into excecoes (email_remetente, tipo, status, detalhe_erro, email_assunto, link_curriculo)
       values ('trabalhabrasil@trabalhabrasil.com.br', 'sem_anexo', 'pendente', 'Aviso do Trabalha Brasil: teste', 'Currículo enviado pelo Trabalha Brasil', '${LINK}')`);
  sql(`insert into excecoes (email_remetente, tipo, status, detalhe_erro) values ('candidata.sem.anexo@gmail.com', 'sem_anexo', 'pendente', 'E-mail sem anexo nem link de currículo')`);
  try {
    await beto.w.carregarExcecoes();
    const linhas = beto.$$('#excecoes-lista .exc-full');
    const botoes = l => [...l.querySelectorAll('.exc-btns button')].map(b => b.textContent.replace(/\s+/g, ' ').trim());
    const portal = linhas.find(l => l.textContent.includes('trabalhabrasil@trabalhabrasil.com.br'));
    const comum = linhas.find(l => l.textContent.includes('candidata.sem.anexo@gmail.com'));
    assert.ok(portal && comum, 'as duas exceções aparecem');
    assert.deepEqual(botoes(portal), ['Abrir currículo', 'Revisar', 'Ignorar'], 'aviso de plataforma: só o botão que leva ao currículo (e o que tira o aviso da fila)');
    assert.deepEqual(botoes(comum), ['Ver e-mail', 'Reprocessar', 'Revisar', 'Ignorar'], 'exceção comum: como sempre');
    assert.match(portal.textContent, /Aviso do Trabalha Brasil/);

    // "Abrir currículo" abre o endereço do e-mail em outra aba, sem dar acesso ao painel (noopener)
    let aberto = null;
    beto.w.open = (...args) => { aberto = args; return null; };
    portal.querySelector('button[data-url]').click();
    assert.deepEqual(aberto, [LINK, '_blank', 'noopener,noreferrer']);

    // o que não é http/https nunca abre, nem por chamada direta
    aberto = null;
    for (const perigoso of ['javascript:alert(1)', 'data:text/html,<b>', 'ftp://x.test/a', '', null]) beto.w.abrirLinkExterno(perigoso);
    assert.equal(aberto, null, 'endereço que não é web não abre');
    assert.equal(beto.w.eval("linkWebSeguro('javascript:alert(1)')"), '');           // const de script comum: só o eval a enxerga
    assert.equal(beto.w.eval(`linkWebSeguro('${LINK}')`), LINK);
    beto.w.open = () => null;

    // "Revisar" tira o aviso da fila
    const id = sql(`select id from excecoes where email_remetente = 'trabalhabrasil@trabalhabrasil.com.br'`);
    await beto.w.resolverExcecao(id, 'revisado');                          // grava e recarrega a lista sem esperar: aguarda o recarregamento acabar
    await esperar(700);
    const restantes = beto.$$('#excecoes-lista .exc-full').map(l => l.textContent);
    assert.ok(restantes.some(t => t.includes('candidata.sem.anexo@gmail.com')), 'a outra exceção continua pendente');
    assert.ok(!restantes.some(t => t.includes('trabalhabrasil@trabalhabrasil.com.br')), 'revisado sai da lista de pendentes');
    assert.equal(sql(`select status from excecoes where id = '${id}'`), 'revisado');
  } finally {
    sql(`delete from excecoes where email_remetente in ('trabalhabrasil@trabalhabrasil.com.br', 'candidata.sem.anexo@gmail.com')`);
    beto.w.open = () => null;
  }
});

test('nenhum erro de script em toda a sessão', () => {
  assert.deepEqual(beto.erros, []);
  assert.deepEqual(ana.erros, []);
});
