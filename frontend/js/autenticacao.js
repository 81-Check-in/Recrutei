// ═══════════════════════════════════════════════════════════
//  AUTENTICAÇÃO
// ═══════════════════════════════════════════════════════════

function definirSenhaVisivel(visivel) {
  $('#l-senha').type = visivel ? 'text' : 'password';
  const btn = $('#btn-olho');
  btn.innerHTML = `<i class="ti ti-eye${visivel ? '-off' : ''}"></i>`;
  btn.setAttribute('aria-label', visivel ? 'Ocultar senha' : 'Mostrar senha');
  btn.setAttribute('aria-pressed', String(visivel));
}

function alternarSenha() {
  definirSenhaVisivel($('#l-senha').type === 'password');
}

async function entrar(ev) {
  ev?.preventDefault();
  const email = $('#l-email').value.trim();
  const senha = $('#l-senha').value;
  const btn   = $('#btn-login');

  if (!email || !senha) { toast('Preencha e-mail e senha', 'erro'); return; }

  btn.disabled = true;
  btn.innerHTML = '<i class="ti ti-loader-2 girando"></i> Entrando...';

  const { data, error } = await db.auth.signInWithPassword({ email, password: senha });

  btn.disabled = false;
  btn.innerHTML = '<i class="ti ti-login"></i> Entrar';

  if (error) {
    toast(error.message === 'Invalid login credentials'
      ? 'E-mail ou senha incorretos' : error.message, 'erro');
    return;
  }
  await iniciarSessao(data.user);
}

async function iniciarSessao(user) {
  let perfil, error;
  try {
    ({ data: perfil, error } = await db.from('usuarios').select('*').eq('id', user.id).single());
  } catch (e) {
    error = e;
  }

  if (error && pareceApiOffline(error)) {
    mostrarEstadoCheio(navigator.onLine ? 'api-offline' : 'offline', () => iniciarSessao(user));
    return;
  }
  if (error || !perfil) {
    toast('Perfil não encontrado. Contate o administrador.', 'erro');
    await db.auth.signOut();
    return;
  }
  if (!perfil.ativo) {
    toast('Usuário inativo. Contate o administrador.', 'erro');
    await db.auth.signOut();
    return;
  }

  app.usuario = user;
  app.perfil  = perfil;

  $('#user-nome').textContent = perfil.nome;
  $('#user-cargo').textContent = perfil.cargo;
  $('#user-av').textContent = perfil.iniciais || iniciais(perfil.nome);

  // Administrador vê o item de Configurações
  $('#nav-config').style.display =
    perfil.perfil === 'administrador' ? 'flex' : 'none';

  db.from('usuarios').update({ ultimo_acesso: new Date().toISOString() })
    .eq('id', user.id).then(() => {});

  document.body.classList.add('logado');
  esconderEstadoCheio();
  if (!await carregarBase()) {
    mostrarEstadoCheio(navigator.onLine ? 'api-offline' : 'offline', () => iniciarSessao(user));
    return;
  }
  irPara('dashboard');
}

async function sair() {
  await db.auth.signOut();
  app.usuario = null; app.perfil = null;
  document.body.classList.remove('logado');
  $('#l-email').value = ''; $('#l-senha').value = '';
  definirSenhaVisivel(false);
}

async function recuperarSenha() {
  const email = $('#f-email').value.trim();
  if (!email) { toast('Informe o e-mail', 'erro'); return; }
  // O link do e-mail volta para este painel. Essa URL precisa estar em
  // Supabase → Authentication → URL Configuration → Redirect URLs.
  const redirectTo = location.protocol.startsWith('http')
    ? location.origin + location.pathname : undefined;
  const { error } = await db.auth.resetPasswordForEmail(email, { redirectTo });
  fecharModal('modal-forgot');
  // O Supabase não revela se o e-mail existe, então a resposta é a mesma nos dois casos
  toast(error ? (MSG_AUTH[error.code] || error.message)
              : 'Se o e-mail estiver cadastrado, você receberá as instruções',
        error ? 'erro' : 'ok');
}

// Fim do fluxo do link de recuperação: o usuário define a nova senha (ou desiste e sai)
function encerrarRecuperacao() {
  fecharModal('modal-nova-senha');
  $('#ns-senha').value = ''; $('#ns-confirma').value = '';
  history.replaceState(null, '', location.pathname + location.search);
}

async function salvarNovaSenha(ev) {
  ev.preventDefault();
  const senha = $('#ns-senha').value;
  if (senha.length < 8) { toast('A senha precisa ter pelo menos 8 caracteres', 'erro'); return; }
  if (senha !== $('#ns-confirma').value) { toast('As senhas não conferem', 'erro'); return; }

  const btn = $('#btn-nova-senha');
  btn.disabled = true;
  const { data, error } = await db.auth.updateUser({ password: senha });
  btn.disabled = false;

  if (error) { toast(MSG_AUTH[error.code] || error.message, 'erro'); return; }
  encerrarRecuperacao();
  toast('Senha alterada com sucesso');
  await iniciarSessao(data.user);
}

// Desistir encerra a sessão que o link abriu, para não deixar o painel destrancado
async function cancelarNovaSenha() {
  encerrarRecuperacao();
  await db.auth.signOut();
}

