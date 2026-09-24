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
    const [setores, empresas, funcoes, niveis] = await Promise.all([
      db.from('setores').select('*').eq('ativo', true).order('ordem'),
      db.from('empresas').select('*').eq('ativo', true).order('sigla'),
      db.from('funcoes_setor').select('setor_id,nome,aceita_iniciante').eq('ativo', true).order('nome'),
      db.from('niveis_funcao').select('codigo,nome').eq('ativo', true).order('ordem')
    ]);
    if (setores.error || empresas.error) throw setores.error || empresas.error;
    // funções e níveis só alimentam o formulário da vaga: se faltarem, o formulário avisa em vez de derrubar o app
    app.cache.funcoes  = funcoes.data || [];
    app.cache.niveis   = niveis.data  || [];
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
  banco: 'Banco de Talentos', candidatos: 'Candidatos em processo',
  entrevistas: 'Entrevistas', sanitizacao: 'Sanitização', listanegra: 'Lista negra', config: 'Configurações'
};

let navAnterior = -1;   // posição do item de menu anterior, para a direção da animação

function irPara(tela, el) {
  app.telaAtual = tela;
  if (tela === 'banco' && el) rankingVaga = null;           // clicou no menu: banco inteiro, não o ranking de uma vaga
  if (tela === 'candidatos' && el) vagaEmProcesso = null;   // clicou no menu: todos os candidatos em processo, não os de uma vaga
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
     banco: carregarBanco, candidatos: carregarCandidatos,
     entrevistas: carregarEntrevistas, sanitizacao: carregarSanitizacao, listanegra: carregarListaNegra,
     config: carregarConfig }[tela])?.();
}

