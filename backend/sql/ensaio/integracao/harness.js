// Apoio do teste de integração do painel (ver frontend.test.js): abre o painel real em um DOM simulado.
const fs = require('node:fs');
const path = require('node:path');
const crypto = require('node:crypto');
const { execFileSync } = require('node:child_process');
const { JSDOM, VirtualConsole } = require('jsdom');

const REST = process.env.REST_URL || 'http://localhost:3000';
const SEGREDO = process.env.JWT_SECRET || 'super-secret-jwt-token-with-at-least-32-characters-long';
const CONTAINER = process.env.PG_CONTAINER || 'pg-ensaio-recrutei';
const FRONTEND = path.resolve(__dirname, '../../../../frontend');

const BETO = '00000000-0000-0000-0000-0000000000b1';    // gerente de RH
const ANA = '00000000-0000-0000-0000-0000000000a1';     // administradora
const DANI = '00000000-0000-0000-0000-0000000000c9';    // usuária INATIVA

// ── apoio ────────────────────────────────────────────────────────────────
const sql = q => execFileSync('docker', ['exec', CONTAINER, 'psql', '-U', 'postgres', '-d', 'rec', '-At', '-c', q], { encoding: 'utf8' }).trim();
const sqlNum = q => Number(sql(q));

function jwt(sub) {
  const b64 = o => Buffer.from(JSON.stringify(o)).toString('base64url');
  const corpo = `${b64({ alg: 'HS256', typ: 'JWT' })}.${b64({ role: 'authenticated', sub, aud: 'authenticated', exp: Math.floor(Date.now() / 1000) + 3600 })}`;
  return `${corpo}.${crypto.createHmac('sha256', SEGREDO).update(corpo).digest('base64url')}`;
}

const ORDEM_SCRIPTS = ['nucleo', 'autenticacao', 'navegacao', 'dashboard', 'vagas', 'banco-talentos', 'candidatos',
  'entrevistas', 'sanitizacao', 'lista-negra', 'consideracoes', 'configuracoes', 'ui-global', 'inicializacao'];

// Abre o painel como um usuário: monta o DOM do index.html, injeta o supabase-js (o mesmo da CDN) apontando para o
// PostgREST local com o JWT do usuário, e roda os scripts do painel na ordem do HTML.
async function abrirPainel(usuarioId, perfil = 'gerente_rh', { apiUrl = '' } = {}) {
  const erros = [];
  const virtualConsole = new VirtualConsole();
  virtualConsole.on('jsdomError', e => { if (!/Not implemented/.test(e.message)) erros.push(e.stack || e.message); });
  // O jsdom não traz tudo o que o painel usa; os stubs entram ANTES do HTML ser interpretado (o <script> de tema do
  // <head> já roda matchMedia na leitura da página).
  const dom = new JSDOM(fs.readFileSync(path.join(FRONTEND, 'index.html'), 'utf8'), {
    url: 'http://localhost/', runScripts: 'dangerously', pretendToBeVisual: true, virtualConsole,
    beforeParse(janela) {
      // o gateway do Supabase tira o prefixo /rest/v1 antes de chegar ao PostgREST; aqui fazemos o mesmo
      janela.fetch = (entrada, opcoes) => fetch(String(entrada?.url ?? entrada).replace('/rest/v1', ''), opcoes);
      Object.assign(janela, { Headers, Request, Response, AbortController,
        ResizeObserver: class { observe() {} disconnect() {} } });
      janela.matchMedia = () => ({ matches: false, addEventListener() {}, removeEventListener() {} });
      janela.Element.prototype.getAnimations = () => [];
      janela.Element.prototype.animate = () => ({ cancel() {} });
    } });
  const w = dom.window;

  const injetar = codigo => { const s = w.document.createElement('script'); s.textContent = codigo; w.document.body.appendChild(s); };
  injetar(fs.readFileSync(require.resolve('@supabase/supabase-js/dist/umd/supabase.js'), 'utf8'));
  injetar(`(() => { const original = window.supabase.createClient;
    window.supabase.createClient = (url, key, opts) => original(${JSON.stringify(REST)}, key, { ...opts,
      auth: { persistSession: false, autoRefreshToken: false },
      global: { headers: { Authorization: 'Bearer ${jwt(usuarioId)}' } } }); })();`);
  for (const nome of ORDEM_SCRIPTS) {
    let codigo = fs.readFileSync(path.join(FRONTEND, 'js', `${nome}.js`), 'utf8');
    // API_URL é uma constante que o dono do sistema preenche à mão em nucleo.js; o teste injeta uma URL falsa sem mexer no arquivo
    if (nome === 'nucleo' && apiUrl) codigo = codigo.replace("const API_URL = '';", `const API_URL = '${apiUrl}';`);
    injetar(codigo);
  }

  // usuário "logado" e capturas para conferir mensagens
  const toasts = [];
  const nomeUsuario = { [BETO]: 'Beto RH', [ANA]: 'Ana Admin', [DANI]: 'Dani Inativa' }[usuarioId];
  w.eval(`app.usuario = { id: ${JSON.stringify(usuarioId)} }; app.perfil = { nome: ${JSON.stringify(nomeUsuario)}, perfil: ${JSON.stringify(perfil)} };`);
  w.toast = (mensagem, tipo = 'ok') => { toasts.push({ mensagem, tipo }); };
  w.confirmar = async () => true;                       // o modal de confirmação é testado à parte; aqui o RH sempre confirma
  w.prompt = () => 'Motivo informado no teste';
  w.open = () => null;
  await w.eval('carregarBase()');                        // setores e empresas, como no login

  const $ = s => w.document.querySelector(s);
  const $$ = s => [...w.document.querySelectorAll(s)];
  return { w, $, $$, toasts, erros, fim: () => w.close(),
    ultimoToast: () => toasts.at(-1)?.mensagem ?? '',
    define: (seletor, valor) => { const el = $(seletor); if (el.type === 'checkbox') el.checked = !!valor; else el.value = valor; } };
}

module.exports = { REST, BETO, ANA, DANI, sql, sqlNum, abrirPainel };
