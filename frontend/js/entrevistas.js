// ═══════════════════════════════════════════════════════════
//  ENTREVISTAS
// ═══════════════════════════════════════════════════════════

let mesAtual = new Date();

async function carregarEntrevistas() {
  await Promise.all([carregarCalendario(), carregarEntrevistasDia(), carregarProximas()]);
}

async function carregarCalendario() {
  const ini = new Date(mesAtual.getFullYear(), mesAtual.getMonth(), 1);
  const fim = new Date(mesAtual.getFullYear(), mesAtual.getMonth()+1, 0, 23, 59, 59);

  const { data } = await db.from('vw_agenda_entrevistas')
    .select('data_hora')
    .gte('data_hora', ini.toISOString())
    .lte('data_hora', fim.toISOString());

  const comEvento = new Set((data||[]).map(e => new Date(e.data_hora).getDate()));

  $('#cal-titulo').textContent = mesAtual.toLocaleDateString('pt-BR',
    { month: 'long', year: 'numeric' });

  const primeiroDia = ini.getDay();
  const totalDias   = fim.getDate();
  const hoje = new Date();
  const ehMesAtual = hoje.getMonth() === mesAtual.getMonth()
                  && hoje.getFullYear() === mesAtual.getFullYear();

  const ehMesSelecionado = diaSelecionado.getMonth() === mesAtual.getMonth()
                        && diaSelecionado.getFullYear() === mesAtual.getFullYear();

  let html = ['Dom','Seg','Ter','Qua','Qui','Sex','Sáb']
    .map(d => `<div class="cal-dow">${d}</div>`).join('');
  for (let i = 0; i < primeiroDia; i++) html += '<div class="cal-day vazio"></div>';
  for (let d = 1; d <= totalDias; d++) {
    const cls = [
      'cal-day',
      (ehMesAtual && d === hoje.getDate()) ? 'hoje' : '',
      comEvento.has(d) ? 'com-evento' : '',
      (ehMesSelecionado && d === diaSelecionado.getDate()) ? 'selecionado' : ''
    ].filter(Boolean).join(' ');
    html += `<div class="${cls}" onclick="selecionarDia(${d}, this)">${d}</div>`;
  }
  $('#cal-grid').innerHTML = html;
}

function mudarMes(delta) {
  mesAtual = new Date(mesAtual.getFullYear(), mesAtual.getMonth()+delta, 1);
  carregarCalendario();
}

let diaSelecionado = new Date();

function selecionarDia(d, el) {
  diaSelecionado = new Date(mesAtual.getFullYear(), mesAtual.getMonth(), d);
  $$('#cal-grid .cal-day.selecionado').forEach(c => c.classList.remove('selecionado'));
  el?.classList.add('selecionado');
  carregarEntrevistasDia();
}

async function carregarEntrevistasDia() {
  const el = $('#entrevistas-dia');
  const ini = new Date(diaSelecionado); ini.setHours(0,0,0,0);
  const fim = new Date(diaSelecionado); fim.setHours(23,59,59,999);

  const ehHoje = ini.toDateString() === new Date().toDateString();
  $('#dia-titulo').textContent = ehHoje
    ? `Hoje — ${ini.toLocaleDateString('pt-BR',{day:'numeric',month:'long'})}`
    : ini.toLocaleDateString('pt-BR',{day:'numeric',month:'long',year:'numeric'});

  const { data, error } = await db.from('vw_agenda_entrevistas')
    .select('*')
    .gte('data_hora', ini.toISOString())
    .lte('data_hora', fim.toISOString())
    .order('data_hora');

  if (error) { erro(el, error.message); return; }

  $('#dia-count').textContent = `${data.length} ${data.length === 1 ? 'entrevista' : 'entrevistas'}`;

  if (!data.length) {
    vazio(el, 'ti-calendar-off', 'Nenhuma entrevista neste dia');
    return;
  }

  const COR = { agendada:'var(--blue)', aprovado:'var(--green)',
                reprovado:'var(--red)', nao_compareceu:'var(--purple)',
                remarcada:'var(--yellow)' };

  el.innerHTML = data.map(e => `
    <div class="ent-item">
      <div class="ent-hora">${fmtHora(e.data_hora)}<span>${fmtHora(e.data_hora_fim)}</span></div>
      <div class="ent-dot" style="background:${COR[e.resultado]||'var(--gray-text)'}"></div>
      <div class="ent-info">
        <div class="ent-nome">${escapeHtml(e.candidato_nome||'—')}</div>
        <div class="ent-meta">${escapeHtml(e.setor_nome||'—')}${e.local ? ' · '+escapeHtml(e.local) : ''}</div>
      </div>
      <div class="ent-acoes">
        <button class="btn-sm" onclick="verCurriculo('${e.candidatura_id}')" title="Ver currículo">
          <i class="ti ti-file-text"></i></button>
        ${e.resultado === 'agendada' ? botaoExcluirEntrevista(e) : ''}
        ${e.resultado === 'agendada' || e.resultado === 'remarcada'
          ? `<button class="btn-sm verde" data-id="${e.id}" data-nome="${escapeHtml(e.candidato_nome)}" data-candidatura="${e.candidatura_id}" data-tel="${escapeHtml(e.candidato_telefone_e164||'')}" onclick="abrirResultado(this.dataset.id, this.dataset.nome, this.dataset.candidatura, this.dataset.tel)">
               <i class="ti ti-check"></i>Resultado</button>`
          : `<span class="pill ${e.resultado==='aprovado'?'pill-green':e.resultado==='reprovado'?'pill-red':'pill-purple'}">
               ${e.resultado==='aprovado'?'Aprovado':e.resultado==='reprovado'?'Reprovado':'Não compareceu'}</span>`}
      </div>
    </div>`).join('');
}

async function carregarProximas() {
  const el = $('#proximas-body');

  const { data, error } = await db.from('vw_agenda_entrevistas')
    .select('*')
    .gte('data_hora', new Date().toISOString())
    .in('resultado', ['agendada','remarcada'])
    .order('data_hora').limit(20);

  if (error) {
    el.innerHTML = `<tr><td colspan="5"><div class="estado-vazio erro"><i class="ti ti-alert-triangle"></i><p>${escapeHtml(error.message)}</p></div></td></tr>`;
    return;
  }
  if (!data.length) {
    el.innerHTML = `<tr><td colspan="5"><div class="estado-vazio">
      <i class="ti ti-calendar"></i><p>Nenhuma entrevista agendada</p></div></td></tr>`;
    return;
  }

  el.innerHTML = data.map(e => `
    <tr>
      <td><div class="cand-row">
        <div class="cand-av">${iniciais(e.candidato_nome)}</div>
        <div><div class="cand-nome">${escapeHtml(e.candidato_nome||'—')}</div>
             <div class="cand-tel">${escapeHtml(e.candidato_telefone||'—')}</div></div>
      </div></td>
      <td>${escapeHtml(e.setor_nome||'—')}</td>
      <td>${fmtDataHora(e.data_hora)}</td>
      <td><span class="pill pill-blue">Agendada</span></td>
      <td class="td-acoes">
        <button class="btn-sm" onclick="verCurriculo('${e.candidatura_id}')" title="Ver currículo">
          <i class="ti ti-file-text"></i></button>
        <button class="btn-sm azul" data-candidatura="${e.candidatura_id}" data-nome="${escapeHtml(e.candidato_nome)}" data-tel="${escapeHtml(e.candidato_telefone_e164||'')}" data-entrevista="${e.id}" onclick="abrirAgendamento(this.dataset.candidatura, this.dataset.nome, this.dataset.tel, this.dataset.entrevista)">
          <i class="ti ti-brand-whatsapp"></i>Remarcar</button>
        ${e.resultado === 'agendada' ? botaoExcluirEntrevista(e) : ''}
      </td>
    </tr>`).join('');
}

function botaoExcluirEntrevista(e) {
  return `<button class="btn-sm vermelho" data-id="${e.id}" data-nome="${escapeHtml(e.candidato_nome||'')}" data-quando="${e.data_hora}" onclick="excluirEntrevista(this.dataset.id, this.dataset.nome, this.dataset.quando)" title="Excluir (agendamento feito por engano)">
    <i class="ti ti-trash"></i></button>`;
}

async function excluirEntrevista(id, nome, dataHora) {
  if (!await confirmar({
    titulo: 'Excluir entrevista', rotulo: 'Excluir',
    mensagem: `Excluir a entrevista de ${nome} em ${fmtDataHora(dataHora)}?\n\nUse apenas para agendamento feito por engano. Não é possível desfazer.`
  })) return;

  const { error } = await db.rpc('excluir_entrevista', { p_id: id });
  if (error) {
    // PGRST202 = função ainda não criada no banco (falta rodar backend/sql/excluir_entrevista.sql)
    toast(error.code === 'PGRST202'
      ? 'Exclusão ainda não habilitada no banco. Rode backend/sql/excluir_entrevista.sql.'
      : error.message, 'erro');
    return;
  }

  toast('Entrevista excluída');
  carregarEntrevistas();
}

// ── Agendamento + WhatsApp ──
function abrirAgendamento(candidaturaId, nome, telefone, entrevistaAnteriorId) {
  app.entrevistaAberta = {
    candidaturaId, nome, telefone,
    anteriorId: entrevistaAnteriorId || null
  };

  const amanha = new Date(); amanha.setDate(amanha.getDate()+1);
  $('#ag-nome').value = nome || '';
  $('#ag-data').value = amanha.toISOString().slice(0,10);
  $('#ag-hora').value = '09:00';
  $('#ag-local').value = '';
  atualizarMensagem();
  abrirModal('modal-agendar');
}

function atualizarMensagem() {
  const nome = $('#ag-nome').value || '[candidato]';
  const data = $('#ag-data').value
    ? new Date($('#ag-data').value+'T12:00:00').toLocaleDateString('pt-BR')
    : '[data]';
  const hora = $('#ag-hora').value || '[hora]';
  const gestor = app.perfil?.nome || 'RH';

  const msg = `Olá ${nome}, meu nome é ${gestor} e você terá uma entrevista no dia ${data} às ${hora}.\nConfirme essa mensagem por favor.`;
  $('#ag-msg').value = msg;
  $('#ag-preview').textContent = msg;
}

function previewMensagem() {
  $('#ag-preview').textContent = $('#ag-msg').value;
}

let agendando = false;

async function confirmarAgendamento() {
  const info = app.entrevistaAberta;
  if (!info || agendando) return;

  const data = $('#ag-data').value;
  const hora = $('#ag-hora').value;
  if (!data || !hora) { toast('Informe data e horário', 'erro'); return; }

  const dataHora = new Date(`${data}T${hora}:00`).toISOString();
  const msg = $('#ag-msg').value;

  agendando = true;
  const btn = $('#ag-confirmar');
  btn.disabled = true;
  try {
    // Agendamento novo (não é remarcação): recusa se já existe entrevista ativa
    if (!info.anteriorId) {
      const { data: ativas, error: erroAtiva } = await db.from('vw_agenda_entrevistas')
        .select('data_hora')
        .eq('candidatura_id', info.candidaturaId)
        .in('resultado', ['agendada','remarcada'])
        .limit(1);
      if (erroAtiva) { toast(erroAtiva.message, 'erro'); return; }
      if (ativas.length) {
        toast(`${info.nome} já tem entrevista em ${fmtDataHora(ativas[0].data_hora)}. Para mudar, use "Remarcar" na tela Entrevistas.`, 'erro');
        return;
      }
    }

    const { error } = await db.from('entrevistas').insert({
      candidatura_id: info.candidaturaId,
      data_hora: dataHora,
      local: $('#ag-local').value.trim() || null,
      entrevistador: app.perfil?.nome || null,
      mensagem_enviada: msg,
      whatsapp_aberto_em: new Date().toISOString(),
      agendado_por: app.usuario.id,
      entrevista_anterior_id: info.anteriorId
    });

    if (error) {
      // 23505 = índice único: esta entrevista já foi remarcada por outra pessoa/aba
      toast(error.code === '23505'
        ? 'Esta entrevista já foi remarcada. Atualize a tela.'
        : error.message, 'erro');
      return;
    }

    // Abre o WhatsApp do gestor com a mensagem pronta
    const tel = normalizaTelefone(info.telefone);
    if (tel) {
      window.open(`https://api.whatsapp.com/send?phone=${tel}&text=${encodeURIComponent(msg)}`, '_blank');
    } else {
      toast('Entrevista registrada, mas o telefone não pôde ser lido', 'erro');
    }

    fecharModal('modal-agendar');
    toast('Entrevista registrada no calendário');

    if (app.telaAtual === 'entrevistas') carregarEntrevistas();
    if (app.telaAtual === 'candidatos')  carregarCandidatos();
    if (app.telaAtual === 'triagem')     carregarTriagem();
  } finally {
    agendando = false;
    btn.disabled = false;
  }
}

// ── Resultado da entrevista ──
function abrirResultado(entrevistaId, nome, candidaturaId, telefone) {
  app.entrevistaAberta = { entrevistaId, nome, candidaturaId, telefone };
  $('#res-nome').textContent = nome;
  $('#res-obs').value = '';
  abrirModal('modal-resultado');
}

async function registrarResultado(resultado) {
  const info = app.entrevistaAberta;
  if (!info) return;

  const { error } = await db.from('entrevistas').update({
    resultado,
    observacoes: $('#res-obs').value.trim() || null,
    resultado_registrado_em: new Date().toISOString(),
    resultado_registrado_por: app.usuario.id
  }).eq('id', info.entrevistaId);

  if (error) { toast(error.message, 'erro'); return; }

  fecharModal('modal-resultado');
  const MSG = {
    aprovado: `${info.nome} aprovado`,
    reprovado: `Resultado registrado — ${info.nome} reprovado`,
    nao_compareceu: `Falta registrada — ${info.nome} não compareceu`
  };
  toast(MSG[resultado] || 'Resultado registrado');
  carregarEntrevistas();
}

function remarcarEntrevista() {
  const info = app.entrevistaAberta;
  fecharModal('modal-resultado');
  abrirAgendamento(info.candidaturaId, info.nome, info.telefone, info.entrevistaId);
}

