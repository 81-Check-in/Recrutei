// ═══════════════════════════════════════════════════════════
//  DADOS BASE
// ═══════════════════════════════════════════════════════════

// Ordem de exibição das lojas; siglas novas (fora da lista) vão para o fim
const ORDEM_EMPRESAS = ['CFS', 'CFR', 'CFVP', 'CFC', 'CFW3', 'CFT', 'CFG', 'CFJB', 'CFPA', 'CFBS'];
const posicaoEmpresa = sigla => {
  const i = ORDEM_EMPRESAS.indexOf(String(sigla).toUpperCase());
  return i === -1 ? ORDEM_EMPRESAS.length : i;
};

// Devolve true/false: iniciarSessao() usa o resultado para decidir se mostra a
// tela cheia de "API fora do ar" (sem os setores/empresas, o app não funciona).
async function carregarBase() {
  try {
    const [setores, empresas] = await Promise.all([
      db.from('setores').select('*').eq('ativo', true).order('ordem'),
      db.from('empresas').select('*').eq('ativo', true).order('sigla')
    ]);
    if (setores.error || empresas.error) throw setores.error || empresas.error;
    app.cache.setores  = setores.data  || [];
    app.cache.empresas = (empresas.data || []).slice().sort((a, b) =>
      posicaoEmpresa(a.sigla) - posicaoEmpresa(b.sigla) ||
      String(a.sigla).localeCompare(String(b.sigla)));
    return true;
  } catch (e) {
    if (!pareceApiOffline(e)) toast('Não foi possível carregar os dados iniciais: ' + (e.message || e), 'erro');
    return false;
  }
}

// ═══════════════════════════════════════════════════════════
//  NAVEGAÇÃO
// ═══════════════════════════════════════════════════════════

const TITULOS = {
  dashboard: 'Dashboard', vagas: 'Vagas',
  triagem: 'Triagem de Currículos', candidatos: 'Candidatos',
  entrevistas: 'Entrevistas', config: 'Configurações'
};

let navAnterior = -1;   // posição do item de menu anterior, para a direção da animação

function irPara(tela, el) {
  app.telaAtual = tela;
  $$('.nav-item').forEach(n => {
    n.classList.remove('active');
    n.removeAttribute('aria-current');
  });
  const itemAtivo = el || $(`[data-tela="${tela}"]`);
  itemAtivo?.classList.add('active');
  itemAtivo?.setAttribute('aria-current', 'page');
  const idx = [...$$('.nav-item')].indexOf(itemAtivo);
  $('.conteudo').style.setProperty('--dir', idx < navAnterior ? -1 : 1);
  if (idx >= 0) navAnterior = idx;
  $$('.screen').forEach(s => s.classList.remove('active'));
  $('#screen-' + tela)?.classList.add('active');
  if (itemAtivo) deslizarPilula($('#nav-pilula'), itemAtivo, 'y');
  posicionarAbas();
  $('#page-title').textContent = TITULOS[tela] || tela;
  $('#periodo-wrap').style.display = tela === 'dashboard' ? 'flex' : 'none';
  fecharSidebar();

  ({ dashboard: carregarDashboard, vagas: carregarVagas,
     triagem: carregarTriagem, candidatos: carregarCandidatos,
     entrevistas: carregarEntrevistas, config: carregarConfig }[tela])?.();
}

