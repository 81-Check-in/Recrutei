// ═══════════════════════════════════════════════════════════
//  RECRUTEI — Camada de dados (Supabase)
// ═══════════════════════════════════════════════════════════

const SUPABASE_URL  = 'https://iragwjfaczpfbldbgsjv.supabase.co';
const SUPABASE_KEY  = 'sb_publishable_IbWdbj93GKSLp_KXIkm1nw_s9L00E2f';

// URL do serviço "web" do backend no Railway (backend/api.py — uvicorn api:app),
// SEPARADO do worker que lê e-mail. Habilita a avaliação imediata do "Enviar
// currículo" (vagas.js). Vazio = o botão continua funcionando, só que o currículo
// fica na fila normal (avaliado na próxima execução da rotina) em vez de na hora.
const API_URL = '';

// Link de "Esqueci minha senha": o Supabase devolve o token no # da URL e o supabase-js
// o apaga ao processar, então o que interessa é guardado antes de criar o cliente.
const RECUPERANDO_SENHA = /[#&]type=recovery(&|$)/.test(location.hash);
const ERRO_LINK = new URLSearchParams(location.hash.slice(1)).get('error_code');

const db = supabase.createClient(SUPABASE_URL, SUPABASE_KEY, {
  auth: { persistSession: true, autoRefreshToken: true }
});

// Mensagens do Supabase Auth que aparecem para o usuário, em português
const MSG_AUTH = {
  same_password: 'A nova senha precisa ser diferente da atual',
  weak_password: 'Senha fraca: use mais caracteres, com letras e números',
  over_email_send_rate_limit: 'Muitos pedidos de e-mail. Aguarde alguns minutos e tente de novo',
};

// Estado da aplicação
const app = {
  usuario: null,
  perfil: null,
  periodo: 7,
  telaAtual: 'dashboard',
  cache: { setores: [], empresas: [], vagas: [], funcoes: [], niveis: [] },
  candidatoAberto: null,     // candidatura aberta no drawer (candidato ↔ vaga)
  talentoAberto: null,       // candidato aberto no drawer do Banco de Talentos
  entrevistaAberta: null
};

// ─────────────────────────────────────────────
// UTILITÁRIOS
// ─────────────────────────────────────────────
const $  = s => document.querySelector(s);
const $$ = s => document.querySelectorAll(s);

function toast(msg, tipo = 'ok') {
  const t = $('#toast');
  $('#toast-msg').textContent = msg;
  $('#toast-icon').className = tipo === 'erro'
    ? 'ti ti-alert-circle' : 'ti ti-check';
  t.classList.toggle('erro', tipo === 'erro');
  t.classList.add('show');
  clearTimeout(t._timer);
  t._timer = setTimeout(() => t.classList.remove('show'), 3000);
}

function iniciais(nome) {
  if (!nome) return '?';
  // só letras: o resultado é inserido via innerHTML e nunca pode conter marcação
  const letras = nome.trim().split(/\s+/).slice(0, 2)
    .map(n => (n.match(/\p{L}/u) || [''])[0]).join('').toUpperCase();
  return letras || '?';
}

function classeNota(n) {
  if (n == null) return 'nota-vazia';
  if (n >= 76) return 'nota-high';
  if (n >= 51) return 'nota-mid';
  return 'nota-low';
}

function fmtData(iso) {
  if (!iso) return '—';
  return new Date(iso).toLocaleDateString('pt-BR',
    { day: '2-digit', month: '2-digit', year: '2-digit' });
}

function fmtDataHora(iso) {
  if (!iso) return '—';
  return new Date(iso).toLocaleString('pt-BR',
    { day: '2-digit', month: '2-digit', hour: '2-digit', minute: '2-digit' });
}

// Data e hora completas (com o ano), para o que precisa ser exato: quando um e-mail foi enviado
function fmtDataHoraCompleta(iso) {
  if (!iso) return '—';
  return new Date(iso).toLocaleString('pt-BR',
    { day: '2-digit', month: '2-digit', year: 'numeric', hour: '2-digit', minute: '2-digit' });
}

function fmtHora(iso) {
  if (!iso) return '—';
  return new Date(iso).toLocaleTimeString('pt-BR',
    { hour: '2-digit', minute: '2-digit' });
}

function tempoRelativo(iso) {
  if (!iso) return '—';
  const dias = Math.floor((Date.now() - new Date(iso)) / 86400000);
  if (dias === 0) return 'Hoje';
  if (dias === 1) return 'Ontem';
  if (dias < 30)  return `Há ${dias} dias`;
  return fmtData(iso);
}

// Normaliza telefone para o formato do link do WhatsApp
function normalizaTelefone(tel) {
  if (!tel) return null;
  let n = String(tel).replace(/\D/g, '');
  if (n.startsWith('55') && n.length >= 12) return n;
  if (n.length === 11 || n.length === 10) return '55' + n;
  if (n.length === 9 || n.length === 8)   return '5561' + n;
  return n.length >= 12 ? n : null;
}

function escapeHtml(s) {
  if (s == null) return '';
  return String(s).replace(/[&<>"']/g,
    c => ({ '&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#39;' }[c]));
}

// ─────────────────────────────────────────────
// BANCO DE TALENTOS — vocabulário e helpers compartilhados
// ─────────────────────────────────────────────
// Níveis do modelo real (Jovem Aprendiz e Trainee só existem em alguns cargos: funcoes_setor.aceita_iniciante).
// Gerente, Encarregado e Supervisor são cargos, não níveis.
const NIVEIS = { jovem_aprendiz: 'Jovem Aprendiz', trainee: 'Trainee', junior: 'Júnior', pleno: 'Pleno', senior: 'Sênior' };
const NIVEIS_INICIANTES = ['jovem_aprendiz', 'trainee'];
const rotuloNivel = n => NIVEIS[n] || '';

// Situação do candidato no banco: [classe do selo, rótulo]
const STATUS_BANCO = {
  ativo:       ['pill-green', 'Disponível'],
  em_processo: ['pill-blue',  'Em processo'],
  inativo:     ['pill-gray',  'Inativo'],
  expurgado:   ['pill-red',   'Excluído']
};

// Mesma normalização do banco (função norm_busca): minúsculas e sem acento. É com ela que a busca por
// nome/cidade casa com as colunas nome_norm/cidade_norm, que têm índice.
function normBusca(t) {
  return String(t ?? '').toLowerCase().normalize('NFD').replace(/[\u0300-\u036f]/g, '');
}

// Termo do usuário para dentro de um LIKE: % e _ digitados valem como texto, não como curinga
const escaparLike = t => t.replace(/[\\%_]/g, c => '\\' + c);

// "Cidade/UF" para mostrar
const rotuloLocal = c => [c.cidade, c.uf].filter(Boolean).join('/') || '—';

// Rótulo de uma vaga no seletor: "Título — Setor" (sem repetir quando são iguais)
function rotuloVaga(v) {
  const setor = (v.setor_nome || '').trim();
  return setor && setor.toLowerCase() !== (v.titulo || '').trim().toLowerCase()
    ? `${v.titulo} — ${setor}` : v.titulo;
}

// As funções do banco levantam erros em português (ex.: "Este candidato já está em um processo seletivo.").
// PGRST202 = a função não existe: as migrações 020–025 ainda não foram aplicadas.
function mensagemErro(error) {
  if (error?.code === 'PGRST202' || error?.code === 'PGRST205' || /schema cache/.test(error?.message || '')) {
    return 'O Banco de Talentos ainda não foi habilitado no banco de dados. Rode backend/sql/020 a 025.';
  }
  return error?.message || 'Erro inesperado';
}

const ehAdministrador = () => app.perfil?.perfil === 'administrador';

function loading(container, msg = 'Carregando...') {
  container.innerHTML =
    `<div class="estado-vazio"><i class="ti ti-loader-2 girando"></i><p>${msg}</p></div>`;
}

function vazio(container, icone, msg, sub = '') {
  container.innerHTML = `<div class="estado-vazio">
    <i class="ti ${icone}"></i><p>${msg}</p>
    ${sub ? `<span>${sub}</span>` : ''}</div>`;
}

function erro(container, msg) {
  container.innerHTML = `<div class="estado-vazio erro">
    <i class="ti ti-alert-triangle"></i><p>Erro ao carregar</p>
    <span>${escapeHtml(msg)}</span></div>`;
}

// ═══════════════════════════════════════════════════════════
//  LISTAS PAGINADAS
//  Estado de "carregar mais" de uma lista: cresce a cada clique e volta à
//  primeira página sozinho quando os filtros mudam (ver paginaInicialSeFiltroMudou).
// ═══════════════════════════════════════════════════════════

function novoEstadoLista(tamanhoPagina = 50) {
  return { tamanhoPagina, limite: tamanhoPagina, total: 0, chave: null, versao: 0 };
}

function paginaInicialSeFiltroMudou(estado, chaveAtual) {
  if (estado.chave !== chaveAtual) { estado.limite = estado.tamanhoPagina; estado.chave = chaveAtual; }
}

// Cuida do carregando/erro/vazio de uma lista paginada e devolve os dados prontos
// para o chamador desenhar. montarQuery() deve incluir select('*', {count:'exact'})
// e os filtros, mas NÃO o .limit() — este helper aplica o limite da página atual.
async function carregarLista(el, estado, montarQuery, { icone, msg, sub = '', mensagemErro }) {
  if (estado.limite === estado.tamanhoPagina) loading(el);   // só pisca na 1ª página
  const versao = ++estado.versao;
  const { data, error, count } = await montarQuery().limit(estado.limite);
  // Mudou um filtro enquanto esta consulta esperava: a resposta antiga não pode sobrescrever a mais nova
  if (versao !== estado.versao) return null;
  if (error) { erro(el, mensagemErro ? mensagemErro(error) : error.message); return null; }
  estado.total = count ?? data.length;
  if (!data.length) vazio(el, icone, msg, sub);
  return { data, count: estado.total };
}

// Mostra "N de TOTAL" e o botão "Carregar mais" (só aparece se sobrar mais para ver).
function atualizarPaginacao(botaoEl, estado, contadorEl, sufixo = '') {
  if (contadorEl) {
    contadorEl.textContent = estado.total
      ? `${Math.min(estado.limite, estado.total)} de ${estado.total}${sufixo}` : `0${sufixo}`;
  }
  if (!botaoEl) return;
  botaoEl.style.display = estado.total > estado.limite ? 'flex' : 'none';
  botaoEl.disabled = false;
  botaoEl.innerHTML = '<i class="ti ti-chevron-down"></i>Carregar mais';
}

// Erro ao carregar mais: destrava o botão sem mexer no contador (o total continua o mesmo).
function destravarBotaoMais(botaoEl) {
  if (!botaoEl) return;
  botaoEl.disabled = false;
  botaoEl.innerHTML = '<i class="ti ti-chevron-down"></i>Carregar mais';
}

