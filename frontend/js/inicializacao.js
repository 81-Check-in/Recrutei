// ═══════════════════════════════════════════════════════════
//  INICIALIZAÇÃO
// ═══════════════════════════════════════════════════════════

window.addEventListener('DOMContentLoaded', async () => {
  if (!navigator.onLine) mostrarEstadoCheio('offline');   // já abriu sem internet
  aplicarTema(document.documentElement.dataset.theme);
  // As pílulas seguem o layout: o rótulo "Menu" muda de altura quando a fonte carrega (e some no modo
  // compacto), e as abas mudam de largura com a fonte, com os contadores e quando Vagas aparece
  new ResizeObserver(posicionarMenu).observe($('.nav-sec'));
  new ResizeObserver(posicionarAbas).observe($('.tabs'));
  window.addEventListener('resize', reposicionarPilulas);
  // Sem escolha salva, acompanha o sistema em tempo real
  matchMedia('(prefers-color-scheme: dark)').addEventListener('change', e => {
    try { if (localStorage.getItem('recrutei-tema')) return; } catch (_) {}
    aplicarTema(e.matches ? 'dark' : 'light');
  });
  try {
    if (localStorage.getItem('recrutei-sidebar-collapsed') === 'true') {
      document.body.classList.add('sidebar-collapsed');
      $('#sb-collapse').setAttribute('aria-label', 'Expandir menu');
      $('#sb-collapse').title = 'Expandir menu';
    }
  } catch (_) {}
  $('#sidebar').inert = window.matchMedia('(max-width:900px)').matches;
  window.addEventListener('resize', () => {
    $('#sidebar').inert = window.matchMedia('(max-width:900px)').matches && !$('#sidebar').classList.contains('open');
  });
  if (ERRO_LINK) {
    toast('Link inválido ou expirado. Peça outro em "Esqueci minha senha"', 'erro');
    history.replaceState(null, '', location.pathname + location.search);
  }

  // Sessão persistida. Vindo do link de recuperação, pede a nova senha antes de entrar.
  const { data: { session } } = await db.auth.getSession();
  if (RECUPERANDO_SENHA && session?.user) {
    abrirModal('modal-nova-senha');
    $('#ns-senha').focus();
  } else if (session?.user) {
    await iniciarSessao(session.user);
  }

  // Enter no e-mail pula para a senha; Enter na senha envia o formulário
  $('#l-email').addEventListener('keydown', e => {
    if (e.key === 'Enter') { e.preventDefault(); $('#l-senha').focus(); }
  });

  // Sem fechar modal por clique fora: perderia o que foi digitado (só X, Cancelar ou Esc)

  // ESC fecha drawer e modais
  document.addEventListener('keydown', e => {
    if (e.key === 'Escape') {
      fecharSidebar();
      fecharDrawer();
      // A nova senha não fecha com Esc: só "Cancelar", que também encerra a sessão do link
      $$('.modal-overlay.show:not(#modal-nova-senha)').forEach(m => m.classList.remove('show'));
      // Esc na confirmação conta como "Cancelar": destrava quem estiver esperando a resposta
      if (_confirmarResolver) responderConfirmacao(false);
    }
  });

  // Filtros do Banco de Talentos (nome e cidade esperam a pessoa parar de digitar)
  ['filtro-b-area','filtro-b-cargo','filtro-b-nivel','filtro-b-sexo','filtro-b-status','ordem-banco'].forEach(id =>
    $('#'+id).addEventListener('change', carregarBanco));
  const recarregarBanco = debounce(carregarBanco);
  ['busca-banco','filtro-b-cidade'].forEach(id => $('#'+id).addEventListener('input', recarregarBanco));

  // Sanitização: trocar de visão descarta a seleção (as linhas são outras)
  $('#san-visao').addEventListener('change', () => { selecaoSanitizacao.clear(); carregarSanitizacao(); });
  $('#san-prioridade').addEventListener('change', carregarSanitizacao);
  $('#san-busca').addEventListener('input', debounce(carregarSanitizacao));

  $('#filtro-cand-status').addEventListener('change', carregarCandidatos);
  $('#busca-candidatos').addEventListener('input', debounce(carregarCandidatos));

  // Agendamento: atualiza mensagem ao mudar data/hora
  ['ag-data','ag-hora','ag-nome'].forEach(id =>
    $('#'+id).addEventListener('change', atualizarMensagem));
});

