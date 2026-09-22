// ═══════════════════════════════════════════════════════════
//  CANDIDATOS
// ═══════════════════════════════════════════════════════════

const estadoCandidatos = novoEstadoLista(50);

function maisCandidatos() {
  const btn = $('#candidatos-mais');
  if (btn) { btn.disabled = true; btn.innerHTML = '<i class="ti ti-loader-2 girando"></i>Carregando…'; }
  estadoCandidatos.limite += estadoCandidatos.tamanhoPagina;
  carregarCandidatos();
}

async function carregarCandidatos() {
  const el = $('#candidatos-body');

  const status = $('#filtro-cand-status').value;
  const busca  = $('#busca-candidatos').value.trim();
  paginaInicialSeFiltroMudou(estadoCandidatos, JSON.stringify([status, busca]));

  if (estadoCandidatos.limite === estadoCandidatos.tamanhoPagina) {
    el.innerHTML = '<tr><td colspan="6"><div class="estado-vazio"><i class="ti ti-loader-2 girando"></i><p>Carregando...</p></div></td></tr>';
  }

  let q = db.from('vw_candidatos').select('*', { count: 'exact' });
  if (status) q = q.eq('status', status);
  if (busca)  q = q.ilike('nome', `%${busca}%`);

  const { data, error, count } = await q
    .order('selecionado_em', { ascending: false }).limit(estadoCandidatos.limite);

  if (error) {
    el.innerHTML = `<tr><td colspan="6"><div class="estado-vazio erro"><i class="ti ti-alert-triangle"></i><p>${escapeHtml(error.message)}</p></div></td></tr>`;
    destravarBotaoMais($('#candidatos-mais'));
    return;
  }

  estadoCandidatos.total = count ?? data.length;
  atualizarPaginacao($('#candidatos-mais'), estadoCandidatos, $('#candidatos-contador'), ' candidatos');

  if (!data.length) {
    el.innerHTML = `<tr><td colspan="6"><div class="estado-vazio">
      <i class="ti ti-users"></i><p>Nenhum candidato ainda</p>
      <span>Selecione currículos na Triagem para que apareçam aqui</span></div></td></tr>`;
    return;
  }

  const PILL = {
    selecionado:         ['pill-yellow','Ag. entrevista'],
    entrevista_agendada: ['pill-blue','Entrevista agendada'],
    entrevista_realizada:['pill-blue','Entrevistado'],
    aprovado:            ['pill-green','Aprovado'],
    reprovado:           ['pill-red','Reprovado'],
    nao_compareceu:      ['pill-purple','Não compareceu'],
    contratado:          ['pill-green','Contratado'],
    descartado:          ['pill-red','Descartado']
  };

  el.innerHTML = data.map(c => {
    const [cls, lbl] = PILL[c.status] || ['pill-gray', c.status];
    const precisaAgendar = ['selecionado','nao_compareceu'].includes(c.status);
    return `<tr>
      <td><div class="cand-row">
        <div class="cand-av">${iniciais(c.nome)}</div>
        <div><div class="cand-nome">${escapeHtml(c.nome||'—')}</div>
             <div class="cand-tel">${escapeHtml(c.telefone||'—')}</div></div>
      </div></td>
      <td>${escapeHtml(c.setor_nome||'—')}</td>
      <td><span class="pill ${classeNota(c.nota).replace('nota-','pill-').replace('high','green').replace('mid','yellow').replace('low','red')}">${c.nota ?? '—'}</span></td>
      <td>${fmtDataHora(c.selecionado_em)}</td>
      <td><span class="pill ${cls}">${lbl}</span></td>
      <td class="td-acoes">
        <button class="btn-sm" onclick="verCurriculo('${c.id}')" title="Ver currículo"><i class="ti ti-file-text"></i></button>
        ${precisaAgendar
          ? `<button class="btn-sm azul" data-id="${c.id}" data-nome="${escapeHtml(c.nome)}" data-tel="${escapeHtml(c.telefone_e164||'')}" onclick="abrirAgendamento(this.dataset.id, this.dataset.nome, this.dataset.tel)"><i class="ti ti-brand-whatsapp"></i>Agendar</button>`
          : `<button class="btn-sm" onclick="abrirAnalise('${c.id}')"><i class="ti ti-eye"></i>Ver</button>`}
        ${precisaAgendar
          ? `<button class="btn-sm vermelho" data-id="${c.id}" data-nome="${escapeHtml(c.nome||'')}" onclick="removerCandidato(this.dataset.id, this.dataset.nome)" title="Remover da lista de candidatos"><i class="ti ti-trash"></i></button>`
          : ''}
      </td>
    </tr>`;
  }).join('');
}

async function removerCandidato(id, nome) {
  if (!await confirmar({
    titulo: 'Remover candidato', rotulo: 'Remover',
    mensagem: `Remover ${nome || 'este candidato'} da lista de candidatos?\n\nO currículo continua no histórico, marcado como descartado.`
  })) return;

  const { data, error } = await db.from('candidaturas').update({
    status: 'descartado',
    descartado_em: new Date().toISOString(),
    descartado_por: app.usuario.id,
    motivo_descarte: 'Removido da lista de candidatos'
  }).eq('id', id).select('id');

  if (error) { toast(error.message, 'erro'); return; }
  // RLS que bloqueia o update não devolve erro, só zero linhas.
  if (!data?.length) { toast('Sem permissão para remover este candidato.', 'erro'); return; }

  toast(`${nome || 'Candidato'} removido dos candidatos`);
  carregarCandidatos();
}

