// O painel de verdade contra um banco ZERADO (zerar_banco_talentos.sql): toda tela tem que abrir vazia, com a
// mensagem certa, sem erro de script e sem "NaN"/"undefined" na tela. Roda DEPOIS de frontend.test.js (rodar.sh),
// sobre o banco que ele deixou (bem mexido: atribuições, exclusões, sanitização) — o que também põe o script de
// zerar à prova em um estado bagunçado.
const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const { execFileSync } = require('node:child_process');
const { REST, BETO, ANA, sql, sqlNum, abrirPainel } = require('./harness');

const CONTAINER = process.env.PG_CONTAINER || 'pg-ensaio-recrutei';
const SCRIPT = path.resolve(__dirname, '../../zerar_banco_talentos.sql');

const texto = (p, seletor) => p.$(seletor).textContent.replace(/\s+/g, ' ').trim();
const semLixo = (p, seletor) =>
  assert.doesNotMatch(p.$(seletor).textContent, /NaN|undefined|Infinity|\[object/, `lixo na tela em ${seletor}`);
const esperar = ms => new Promise(r => setTimeout(r, ms));

let beto, ana;
test.before(async () => {
  try { await fetch(REST); } catch { throw new Error(`PostgREST não responde em ${REST}. Rode backend/sql/ensaio/integracao/rodar.sh`); }
  assert.ok(sqlNum('select count(*) from candidatos') > 0, 'o banco precisa ter dados para ser zerado');
  const zerar = fs.readFileSync(SCRIPT, 'utf8').replace("'recrutei.zerar_confirmado', 'NAO'", "'recrutei.zerar_confirmado', 'SIM'");
  execFileSync('docker', ['exec', '-i', CONTAINER, 'psql', '-U', 'postgres', '-d', 'rec', '-v', 'ON_ERROR_STOP=1', '-q'],
    { input: zerar, stdio: ['pipe', 'ignore', 'ignore'] });
  beto = await abrirPainel(BETO);
  ana = await abrirPainel(ANA, 'administrador');
});
test.after(() => { beto?.fim(); ana?.fim(); });

test('o banco ficou zerado e o que devia ficar, ficou', () => {
  for (const t of ['candidatos', 'candidaturas', 'curriculos', 'analises_ia', 'avaliacoes', 'entrevistas', 'excecoes', 'uploads_manuais'])
    assert.equal(sqlNum(`select count(*) from ${t}`), 0, t);
  assert.ok(sqlNum('select count(*) from vagas') > 0);
  assert.ok(sqlNum('select count(*) from usuarios') >= 3);
});

test('dashboard: tudo em zero; o funil mostra o estado vazio (sem dividir por zero) e as vagas aparecem', async () => {
  await beto.w.carregarDashboard();
  assert.equal(beto.$('#m-curriculos').textContent.replace(/\D/g, ''), '0');
  assert.equal(beto.$('#m-sanitizacao').textContent, '0');
  assert.equal(beto.$('#m-revisao').textContent, '0');
  assert.equal(beto.$$('#funil .funil-row').length, 0);
  assert.match(texto(beto, '#funil'), /Nenhum candidato no banco/);
  semLixo(beto, '#funil');
  semLixo(beto, '#vagas-resumo');
  assert.deepEqual(beto.erros, []);
});

test('banco de talentos: estado vazio explica como os currículos chegam', async () => {
  await beto.w.carregarBanco();
  assert.equal(beto.$$('#banco-lista .curr-card').length, 0);
  assert.match(texto(beto, '#banco-lista'), /Nenhum candidato encontrado/);
  assert.match(texto(beto, '#banco-lista'), /currículos entram aqui/);
  assert.match(texto(beto, '#banco-total'), /^0 /);
  assert.equal(beto.$('#banco-mais').style.display, 'none');
  semLixo(beto, '#banco-lista');
});

test('banco de talentos: busca e filtros sobre o vazio não quebram', async () => {
  beto.define('#busca-banco', 'qualquer nome');
  beto.define('#filtro-b-cidade', 'brasilia');
  beto.define('#filtro-b-area', 'Logística');
  await beto.w.carregarBanco();
  assert.match(texto(beto, '#banco-lista'), /Nenhum candidato encontrado/);
  beto.w.limparTodosFiltrosBanco();
  await esperar(500);
  beto.w.irBancoRevisao();                       // atalho do dashboard
  await esperar(700);
  assert.match(texto(beto, '#banco-lista'), /Nenhum candidato encontrado/);
  assert.deepEqual(beto.erros, []);
});

test('em processo: estado vazio', async () => {
  await beto.w.carregarCandidatos();
  assert.match(texto(beto, '#candidatos-body'), /Nenhum candidato em processo/);
  semLixo(beto, '#candidatos-body');
});

test('vagas: as vagas continuam, sem candidatos', async () => {
  await beto.w.carregarVagas();
  const cards = beto.$$('.vaga-card');
  assert.ok(cards.length > 0, 'as vagas não foram apagadas');
  semLixo(beto, '.vaga-card');
  assert.match(cards[0].textContent, /No banco/);
});

test('entrevistas: agenda vazia', async () => {
  await beto.w.carregarEntrevistas();
  assert.equal(beto.$$('#proximas-body tr[data-id]').length, 0);
  semLixo(beto, '#proximas-body');
  assert.deepEqual(beto.erros, []);
});

test('sanitização: sem sugestões; o administrador gera a lista e ela sai vazia', async () => {
  await ana.w.carregarSanitizacao();
  assert.match(texto(ana, '#san-body'), /Nenhuma sugestão pendente/);
  await ana.w.gerarSugestoesAgora();
  await ana.w.carregarSanitizacao();
  assert.equal(ana.$$('#san-body tr[data-id]').length, 0);
  assert.equal(sqlNum(`select count(*) from candidatos`), 0, 'gerar a lista não cria nem apaga candidatos');
  semLixo(ana, '#san-body');
  semLixo(ana, '#san-ciclo');
  assert.deepEqual(ana.erros, []);
});

test('configurações: o marcador do e-mail e os parâmetros seguem lá', async () => {
  await ana.w.carregarConfig();
  assert.match(ana.$('#config-lista').textContent, /sanitizacao_intervalo_meses/);
  assert.deepEqual(ana.erros, []);
});

test('nenhum erro de script em toda a sessão', () => {
  assert.deepEqual(beto.erros, []);
  assert.deepEqual(ana.erros, []);
});
