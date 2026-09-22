// ═══════════════════════════════════════════════════════════
//  MODAIS / UI
// ═══════════════════════════════════════════════════════════

function abrirModal(id) { $('#'+id).classList.add('show'); }
function fecharModal(id) { $('#'+id).classList.remove('show'); }

// ── Confirmação (substitui o confirm() nativo) ──
// Uso: if (!await confirmar({ mensagem: '...' })) return;
let _confirmarResolver = null;

function confirmar({ titulo = 'Confirmar ação', mensagem, rotulo = 'Confirmar', perigo = true } = {}) {
  return new Promise(resolve => {
    _confirmarResolver = resolve;
    $('#confirmar-titulo').textContent = titulo;
    $('#confirmar-msg').textContent = mensagem || '';
    const icone = $('#confirmar-icone');
    icone.className = 'ti ' + (perigo ? 'ti-alert-triangle' : 'ti-help-circle');
    icone.style.color = perigo ? 'var(--red)' : 'var(--blue)';
    const ok = $('#confirmar-ok');
    ok.textContent = rotulo;
    ok.classList.toggle('btn-perigo', perigo);
    abrirModal('modal-confirmar');
    // Foco começa em "Cancelar": a ação mais segura, caso a pessoa só dê Enter
    setTimeout(() => $('#confirmar-cancelar')?.focus(), 0);
  });
}

function responderConfirmacao(resposta) {
  fecharModal('modal-confirmar');
  const resolver = _confirmarResolver;
  _confirmarResolver = null;
  resolver?.(resposta);
}

// ═══════════════════════════════════════════════════════════
//  TELA DE ESTADO (sem internet / API fora do ar)
//  Cobre a tela inteira quando o app não tem como funcionar: sem conexão, ou o
//  Supabase não respondeu à primeira chamada crítica (perfil / dados base).
//  Erros pontuais de uma tela específica continuam só com toast() — isto aqui
//  é só para o "não dá pra fazer nada até resolver".
// ═══════════════════════════════════════════════════════════

const TEXTOS_ESTADO = {
  offline: {
    titulo: 'Sem conexão com a internet',
    msg: 'Parece que a internet caiu por aqui. Assim que voltar, a gente recarrega sozinho.',
    aguardando: true
  },
  'api-offline': {
    titulo: 'Nossa IA foi tirar uma soneca',
    msg: 'O servidor não respondeu a tempo. Deve ser só um cochilo — tenta de novo em instantes.',
    aguardando: false
  }
};

let _estadoAoTentarNovamente = null;

function mostrarEstadoCheio(variante, aoTentarNovamente) {
  const cfg = TEXTOS_ESTADO[variante] || TEXTOS_ESTADO['api-offline'];
  $('#estado-titulo').textContent = cfg.titulo;
  $('#estado-msg').textContent = cfg.msg;
  $('#estado-btn').style.display = cfg.aguardando ? 'none' : 'flex';
  $('#estado-aguardando').style.display = cfg.aguardando ? 'flex' : 'none';
  _estadoAoTentarNovamente = aoTentarNovamente || null;
  $('#tela-estado').classList.add('show');
}

function esconderEstadoCheio() {
  $('#tela-estado').classList.remove('show');
  _estadoAoTentarNovamente = null;
}

async function tentarNovamenteEstado() {
  const btn = $('#estado-btn');
  btn.disabled = true;
  try {
    await _estadoAoTentarNovamente?.();
  } finally {
    btn.disabled = false;
  }
}

// Erro de rede (sem resposta nenhuma do servidor) vs. erro de verdade da API/banco
// (que já respondeu, só que com um problema). O Supabase sempre devolve um "code"
// nos erros do banco/RLS; um erro de rede (DNS, servidor fora do ar, CORS) não tem.
function pareceApiOffline(erro) {
  if (!erro) return false;
  if (!navigator.onLine) return true;
  if (erro.code) return false;
  return /fetch|network|conex|timeout/i.test(erro.message || String(erro));
}

window.addEventListener('offline', () => mostrarEstadoCheio('offline'));
window.addEventListener('online', () => {
  if ($('#tela-estado').classList.contains('show')) location.reload();
});

function abrirSidebar() {
  $('#sidebar').inert = false;
  $('#sidebar').classList.add('open');
  $('#mob-overlay').classList.add('show');
  $('#menu-mobile').setAttribute('aria-expanded', 'true');
}
function fecharSidebar() {
  $('#sidebar').classList.remove('open');
  $('#mob-overlay').classList.remove('show');
  $('#menu-mobile').setAttribute('aria-expanded', 'false');
  $('#sidebar').inert = window.matchMedia('(max-width:900px)').matches;
}
function alternarSidebarCompacta() {
  const compacta = document.body.classList.toggle('sidebar-collapsed');
  const botao = $('#sb-collapse');
  const texto = compacta ? 'Expandir menu' : 'Recolher menu';
  botao.setAttribute('aria-label', texto);
  botao.title = texto;
  try { localStorage.setItem('recrutei-sidebar-collapsed', String(compacta)); } catch (_) {}
  reposicionarPilulas();   // o rótulo "Menu" some no modo compacto e os itens sobem
}

// ─────────────────────────────────────────────
// PÍLULA DE VIDRO (menu lateral e abas)
// ─────────────────────────────────────────────
const SEM_MOVIMENTO = matchMedia('(prefers-reduced-motion: reduce)');

// Leva a pílula até o item ativo. Ela viaja inteira, as duas bordas juntas, com um brilho de
// vidro a meio caminho.
// eixo 'y' = menu (top/height), 'x' = abas (left/width). Sem animar, só posiciona.
function deslizarPilula(pilula, alvo, eixo, animar = true) {
  const [pos, tam] = eixo === 'y' ? ['top', 'height'] : ['left', 'width'];
  const destinoPos = eixo === 'y' ? alvo.offsetTop : alvo.offsetLeft;
  const destinoTam = eixo === 'y' ? alvo.offsetHeight : alvo.offsetWidth;
  if (!destinoTam) return;   // tela oculta: reposiciona quando aparecer

  const pronta = pilula.classList.contains('pronta');
  // Lê a posição atual antes de cancelar: um clique no meio da viagem parte de onde a pílula está
  const estilo = getComputedStyle(pilula);
  const origemPos = parseFloat(estilo[pos]);
  const origemTam = parseFloat(estilo[tam]);
  // Reposicionar sem animar só corrige o destino: não interrompe uma viagem em curso
  if (animar) pilula.getAnimations().forEach(a => a.cancel());
  pilula.style[pos] = destinoPos + 'px';
  pilula.style[tam] = destinoTam + 'px';
  pilula.classList.add('pronta');
  if (!animar || !pronta || SEM_MOVIMENTO.matches || Math.abs(origemPos - destinoPos) < 1) return;

  pilula.animate([
    { [pos]: origemPos + 'px', [tam]: origemTam + 'px', filter: 'brightness(1)' },
    { filter: `brightness(${eixo === 'y' ? 1.45 : 1.25}) saturate(1.25)`, offset: .5 },
    { [pos]: destinoPos + 'px', [tam]: destinoTam + 'px', filter: 'brightness(1)' }
  ], { duration: 1080, easing: 'cubic-bezier(.25,.1,.15,1)' });
}

// Recolocam as pílulas sem animar (compactar o menu, redimensionar, fonte ou contador mudou)
function posicionarMenu() {
  const item = $('.nav-item.active');
  if (item) deslizarPilula($('#nav-pilula'), item, 'y', false);
}
function posicionarAbas() {
  const aba = $('.tab.active');
  if (aba) deslizarPilula($('#tabs-pilula'), aba, 'x', false);
}
function reposicionarPilulas() { posicionarMenu(); posicionarAbas(); }

// Tema claro/escuro. O <head> aplica o tema salvo (ou o do sistema) antes de pintar;
// aqui fica a troca manual e o rótulo do botão.
function aplicarTema(tema) {
  document.documentElement.dataset.theme = tema;
  const botao = $('#btn-tema');
  const texto = tema === 'dark' ? 'Ativar modo claro' : 'Ativar modo escuro';
  botao.setAttribute('aria-label', texto);
  botao.title = texto;
}
function alternarTema() {
  const novo = document.documentElement.dataset.theme === 'dark' ? 'light' : 'dark';
  aplicarTema(novo);
  try { localStorage.setItem('recrutei-tema', novo); } catch (_) {}
}

// Debounce para campos de busca
function debounce(fn, ms = 400) {
  let t;
  return (...a) => { clearTimeout(t); t = setTimeout(() => fn(...a), ms); };
}

