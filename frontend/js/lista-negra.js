// ═══════════════════════════════════════════════════════════
//  LISTA NEGRA DE E-MAILS
//  Endereços dos quais o RH não quer mais receber nada (ex.: quem oferece risco à empresa). O pipeline ignora o
//  remetente bloqueado e também o e-mail que aparecer DENTRO do currículo. Bloquear um candidato do banco cancela as
//  candidaturas abertas, inativa-o, bloqueia todos os endereços ligados a ele e o impede de ser atribuído a vagas.
//  As gravações passam por bloquear_email / desbloquear_email (backend/sql/028); o painel não escreve em "remetentes".
//  Qualquer usuário ativo bloqueia e libera; tudo fica na auditoria (quem, quando, motivo).
// ═══════════════════════════════════════════════════════════

const estadoListaNegra = { versao: 0 };
let candidatoParaBloquear = null;          // candidato do modal "Colocar na lista negra"

async function carregarListaNegra() {
  const el = $('#ln-body');
  const busca = $('#ln-busca').value.trim();
  const versao = ++estadoListaNegra.versao;

  let q = db.from('vw_lista_negra').select('*', { count: 'exact' })
    .order('bloqueado_em', { ascending: false }).limit(300);
  if (busca) {
    const t = escaparLike(busca).replace(/[,()]/g, ' ');       // vírgula e parênteses quebrariam o filtro .or()
    q = q.or(`email.ilike.%${t}%,motivo_bloqueio.ilike.%${t}%`);
  }
  const { data, error, count } = await q;
  if (versao !== estadoListaNegra.versao) return;              // outra busca começou enquanto esta esperava

  if (error) {
    el.innerHTML = `<tr><td colspan="5"><div class="estado-vazio erro"><i class="ti ti-alert-triangle"></i><p>${escapeHtml(mensagemErro(error))}</p></div></td></tr>`;
    $('#ln-contador').textContent = 'Não foi possível carregar a lista';
    return;
  }
  const total = count ?? data.length;
  $('#ln-contador').textContent = total === 0 ? 'Nenhum e-mail bloqueado' : `${total} e-mail${total > 1 ? 's' : ''} bloqueado${total > 1 ? 's' : ''}`;

  if (!data.length) {
    el.innerHTML = `<tr><td colspan="5"><div class="estado-vazio"><i class="ti ti-shield-check"></i>
      <p>${busca ? 'Nada encontrado' : 'A lista negra está vazia'}</p>
      <span>${busca ? 'Tente outro trecho do e-mail ou do motivo' : 'Bloqueie um endereço acima, ou use o botão “Lista negra” no cadastro de um candidato'}</span></div></td></tr>`;
    return;
  }

  el.innerHTML = data.map(l => `<tr data-email="${escapeHtml(l.email)}">
    <td><strong>${escapeHtml(l.email)}</strong>
      <div class="ln-sub">${l.total_envios ? `${l.total_envios} e-mail${l.total_envios > 1 ? 's' : ''} recebido${l.total_envios > 1 ? 's' : ''}` : 'Nunca enviou'}</div></td>
    <td>${escapeHtml(l.motivo_bloqueio || '—')}</td>
    <td>${escapeHtml(l.bloqueado_por_nome || '—')}<div class="ln-sub">${l.bloqueado_em ? fmtDataHora(l.bloqueado_em) : ''}</div></td>
    <td>${l.candidato_id
      ? `<a href="#" class="ln-link" onclick="event.preventDefault();abrirTalento('${l.candidato_id}')">${escapeHtml(l.candidato_nome || 'Nome não extraído')}</a>`
      : '<span class="sem-dados">—</span>'}</td>
    <td class="ln-acoes"><button type="button" class="btn-sm" onclick="liberarEmail('${escapeHtml(l.email)}', ${l.candidato_id ? `'${l.candidato_id}'` : 'null'})"
      title="Tira este endereço da lista negra"><i class="ti ti-shield-check"></i>Liberar</button></td>
  </tr>`).join('');
}

// ── Bloquear um endereço (tela "Lista negra") ──
async function bloquearEmailManual() {
  const email = $('#ln-email').value.trim();
  const motivo = $('#ln-motivo').value.trim();
  if (!email || !motivo) { toast('Informe o e-mail e o motivo', 'erro'); return; }

  const btn = $('#ln-btn');
  btn.disabled = true;
  const { data, error } = await db.rpc('bloquear_email', { p_email: email, p_motivo: motivo, p_candidato_id: null });
  btn.disabled = false;
  if (error) { toast(mensagemErro(error), 'erro'); return; }

  $('#ln-email').value = '';
  $('#ln-motivo').value = '';
  const noBanco = data?.candidatos_inativados || 0;
  toast(noBanco ? `E-mail bloqueado. ${noBanco} candidato${noBanco > 1 ? 's' : ''} do banco foi${noBanco > 1 ? 'ram' : ''} junto` : 'E-mail bloqueado');
  opcoesBancoCarregadas = false;
  await carregarListaNegra();
}

// ── Liberar (com o candidato, se o endereço estiver ligado a um) ──
async function liberarEmail(email, candidatoId) {
  if (!await confirmar({
    titulo: 'Tirar da lista negra', rotulo: 'Liberar', perigo: false,
    mensagem: `Voltar a receber e-mails de ${email}?` +
      (candidatoId ? '\n\nO candidato ligado a ele também sai da lista negra, mas continua INATIVO: você decide se o reativa.' : '')
  })) return;
  const { error } = await db.rpc('desbloquear_email', { p_email: email, p_candidato_id: candidatoId || null });
  if (error) { toast(mensagemErro(error), 'erro'); return; }
  toast('E-mail liberado');
  opcoesBancoCarregadas = false;
  await carregarListaNegra();
}

// ── Bloquear um candidato (botão no cadastro) ──
function abrirBloqueioCandidato() {
  const c = app.talentoAberto;
  if (!c) return;
  candidatoParaBloquear = c;
  $('#ln-m-motivo').value = '';
  $('#ln-m-msg').textContent =
    `${c.nome || 'Este candidato'}${c.email ? ` (${c.email})` : ''} vai para a lista negra:\n` +
    '• o e-mail dele e o de quem enviou o currículo passam a ser ignorados;\n' +
    '• as candidaturas abertas são canceladas (entrevistas marcadas deixam de valer);\n' +
    '• ele é inativado e nunca mais pode ser atribuído a uma vaga.\n\n' +
    'Nada é apagado. Você pode tirá-lo da lista depois.';
  abrirModal('modal-lista-negra');
}

async function confirmarBloqueioCandidato() {
  const c = candidatoParaBloquear;
  const motivo = $('#ln-m-motivo').value.trim();
  if (!c) return;
  if (!motivo) { toast('Informe o motivo do bloqueio', 'erro'); return; }
  if (!c.email) { toast('Este candidato não tem e-mail cadastrado. Edite os dados e informe o e-mail antes de bloquear', 'erro'); return; }

  const btn = $('#ln-m-ok');
  btn.disabled = true;
  const { error } = await db.rpc('bloquear_email', { p_email: c.email, p_motivo: motivo, p_candidato_id: c.id });
  btn.disabled = false;
  if (error) { toast(mensagemErro(error), 'erro'); return; }

  fecharModal('modal-lista-negra');
  candidatoParaBloquear = null;
  toast('Candidato colocado na lista negra');
  opcoesBancoCarregadas = false;
  await recarregarTalento();
  if (app.telaAtual === 'listanegra') carregarListaNegra();
}

async function tirarCandidatoDaListaNegra() {
  const c = app.talentoAberto;
  if (!c) return;
  await liberarEmail(c.email || '', c.id);
  await recarregarTalento();
}
