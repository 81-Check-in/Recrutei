// ═══════════════════════════════════════════════════════════
//  VAGAS
// ═══════════════════════════════════════════════════════════

async function carregarVagas() {
  const el = $('#vagas-grid');
  loading(el);

  const { data, error } = await db.from('vw_vagas_resumo')
    .select('*').order('setor_nome');

  if (error) { erro(el, error.message); return; }

  $('#count-vagas').textContent = data.length;

  if (!data.length) {
    vazio(el, 'ti-briefcase', 'Nenhuma vaga cadastrada',
      'Clique em "Nova vaga" para começar');
    return;
  }

  el.innerHTML = data.map(v => `
    <div class="vaga-card">
      <div class="vaga-card-top">
        <div class="vaga-icon" style="background:${v.setor_cor}1a;color:${v.setor_cor}">
          <i class="ti ${v.setor_icone}"></i>
        </div>
        <div class="vaga-actions">
          <button class="action-btn" title="Editar" onclick="abrirModalVaga('${v.id}')">
            <i class="ti ti-pencil"></i></button>
          <button class="action-btn danger" title="Encerrar" data-id="${v.id}" data-titulo="${escapeHtml(v.titulo)}" onclick="encerrarVaga(this.dataset.id, this.dataset.titulo)">
            <i class="ti ti-player-pause"></i></button>
        </div>
      </div>
      <div class="vaga-titulo">${escapeHtml(v.titulo)}</div>
      <div class="vaga-empresa">${escapeHtml(v.empresas || '—')} · ${escapeHtml(v.setor_nome)}</div>
      <div class="vaga-stats">
        <div class="vaga-stat"><div class="vaga-stat-val">${v.total_curriculos}</div><div class="vaga-stat-lbl">Currículos</div></div>
        <div class="vaga-stat"><div class="vaga-stat-val">${v.total_selecionados}</div><div class="vaga-stat-lbl">Selecionados</div></div>
        <div class="vaga-stat"><div class="vaga-stat-val">${v.total_entrevistas}</div><div class="vaga-stat-lbl">Entrevistas</div></div>
      </div>
      <div class="vaga-footer">
        <span class="pill pill-green"><i class="ti ti-point-filled" style="font-size:10px"></i>
          Ativa · ${v.dias_aberta}d</span>
        <button class="btn-triagem" onclick="irTriagemVaga('${v.id}')">Ver triagem</button>
      </div>
    </div>`).join('');
}

function irTriagemVaga(vagaId) {
  irPara('triagem');
  setTimeout(() => { $('#filtro-vaga').value = vagaId; carregarTriagem(); }, 100);
}

// "TODAS" reflete o estado das lojas: marcada só quando todas estão marcadas
function sincronizarTodasEmpresas() {
  const itens = [...$$('#vaga-empresas input[data-empresa]')];
  $('#vaga-empresas-todas').checked = itens.length > 0 && itens.every(c => c.checked);
}

async function abrirModalVaga(vagaId) {
  const ehEdicao = !!vagaId;
  $('#modal-vaga-titulo').textContent = ehEdicao ? 'Editar vaga' : 'Nova vaga';
  $('#vaga-id').value = vagaId || '';

  $('#vaga-setor').innerHTML = app.cache.setores
    .map(s => `<option value="${s.id}">${escapeHtml(s.nome)}</option>`).join('');

  $('#vaga-empresas').innerHTML = app.cache.empresas.map(e => `
    <label class="chk-empresa">
      <input type="checkbox" data-empresa value="${e.id}"> ${escapeHtml(e.sigla)}
    </label>`).join('') + `
    <label class="chk-empresa chk-todas">
      <input type="checkbox" id="vaga-empresas-todas"> TODAS
    </label>`;
  $('#vaga-empresas').onchange = ev => {
    if (ev.target.id === 'vaga-empresas-todas') {
      $$('#vaga-empresas input[data-empresa]').forEach(c => { c.checked = ev.target.checked; });
    } else {
      sincronizarTodasEmpresas();
    }
  };

  $('#vaga-titulo').value = '';
  $('#vaga-descricao').value = '';
  $('#vaga-perfil').value = '';
  $('#vaga-qtd').value = 1;
  $('#req-list').innerHTML = '';

  if (ehEdicao) {
    const [{ data: v }, { data: reqs }, { data: emps }] = await Promise.all([
      db.from('vagas').select('*').eq('id', vagaId).single(),
      db.from('requisitos').select('*').eq('vaga_id', vagaId).order('ordem'),
      db.from('vaga_empresas').select('empresa_id').eq('vaga_id', vagaId)
    ]);
    if (v) {
      $('#vaga-titulo').value = v.titulo || '';
      $('#vaga-descricao').value = v.descricao || '';
      $('#vaga-perfil').value = v.perfil_comportamental || '';
      $('#vaga-qtd').value = v.quantidade || 1;
      $('#vaga-setor').value = v.setor_id;
    }
    (emps || []).forEach(e => {
      const c = $(`#vaga-empresas input[value="${e.empresa_id}"]`);
      if (c) c.checked = true;
    });
    sincronizarTodasEmpresas();
    (reqs || []).forEach(r => addRequisito(r.descricao, r.tipo, r.peso));
  }
  if (!$('#req-list').children.length) { addRequisito(); addRequisito(); }

  abrirModal('modal-vaga');
}

function addRequisito(desc = '', tipo = 'obrigatorio', peso = 1) {
  const row = document.createElement('div');
  row.className = 'req-row';
  row.innerHTML = `
    <input class="req-input" type="text" placeholder="Ex: CNH categoria B" value="${escapeHtml(desc)}">
    <select class="req-tipo">
      <option value="obrigatorio" ${tipo==='obrigatorio'?'selected':''}>Obrigatório</option>
      <option value="desejavel"  ${tipo==='desejavel' ?'selected':''}>Desejável</option>
    </select>
    <input class="req-peso" type="number" min="1" max="10" value="${peso}" title="Peso 1-10">
    <button class="req-del" onclick="this.parentElement.remove()"><i class="ti ti-trash"></i></button>`;
  $('#req-list').appendChild(row);
}

async function salvarVaga() {
  const id     = $('#vaga-id').value;
  const titulo = $('#vaga-titulo').value.trim();
  if (!titulo) { toast('Informe o título da vaga', 'erro'); return; }

  const payload = {
    setor_id: $('#vaga-setor').value,
    titulo,
    descricao: $('#vaga-descricao').value.trim() || null,
    perfil_comportamental: $('#vaga-perfil').value.trim() || null,
    quantidade: parseInt($('#vaga-qtd').value) || 1,
    atualizado_por: app.usuario.id
  };

  let vagaId = id;
  if (id) {
    const { error } = await db.from('vagas').update(payload).eq('id', id);
    if (error) { toast(error.message, 'erro'); return; }
  } else {
    payload.criado_por = app.usuario.id;
    const { data, error } = await db.from('vagas').insert(payload).select('id').single();
    if (error) { toast(error.message, 'erro'); return; }
    vagaId = data.id;
  }

  // Empresas
  await db.from('vaga_empresas').delete().eq('vaga_id', vagaId);
  const empresas = [...$$('#vaga-empresas input[data-empresa]:checked')]
    .map(c => ({ vaga_id: vagaId, empresa_id: c.value }));
  if (empresas.length) await db.from('vaga_empresas').insert(empresas);

  // Requisitos
  await db.from('requisitos').delete().eq('vaga_id', vagaId);
  const reqs = [...$$('#req-list .req-row')].map((r, i) => ({
    vaga_id: vagaId,
    descricao: r.querySelector('.req-input').value.trim(),
    tipo: r.querySelector('.req-tipo').value,
    peso: parseInt(r.querySelector('.req-peso').value) || 1,
    ordem: i
  })).filter(r => r.descricao);
  if (reqs.length) await db.from('requisitos').insert(reqs);

  fecharModal('modal-vaga');
  toast(id ? 'Vaga atualizada' : 'Vaga criada com sucesso');
  carregarVagas();
}

async function encerrarVaga(id, titulo) {
  if (!await confirmar({
    titulo: 'Encerrar vaga', rotulo: 'Encerrar', perigo: false,
    mensagem: `Encerrar a vaga "${titulo}"?\n\nAs candidaturas recebidas são preservadas no histórico.`
  })) return;
  const { error } = await db.from('vagas').update({
    status: 'inativo',
    deleted_at: new Date().toISOString(),
    data_encerramento: new Date().toISOString().slice(0, 10),
    atualizado_por: app.usuario.id
  }).eq('id', id);
  if (error) { toast(error.message, 'erro'); return; }
  toast('Vaga encerrada');
  carregarVagas();
}

// ── Fila de exceções ──
const estadoExcecoes = novoEstadoLista(50);

function maisExcecoes() {
  const btn = $('#excecoes-mais');
  if (btn) { btn.disabled = true; btn.innerHTML = '<i class="ti ti-loader-2 girando"></i>Carregando…'; }
  estadoExcecoes.limite += estadoExcecoes.tamanhoPagina;
  carregarExcecoes();
}

async function carregarExcecoes() {
  const el = $('#excecoes-lista');

  const montar = () => db.from('excecoes').select('*', { count: 'exact' })
    .eq('status', 'pendente').order('recebido_em', { ascending: false });

  const resultado = await carregarLista(el, estadoExcecoes, montar,
    { icone: 'ti-circle-check', msg: 'Nenhuma exceção pendente',
      sub: 'Tudo que chegou foi processado com sucesso' });

  if (!resultado) { destravarBotaoMais($('#excecoes-mais')); return; }   // erro() já foi desenhado

  $('#count-exc').textContent = estadoExcecoes.total;
  atualizarPaginacao($('#excecoes-mais'), estadoExcecoes, $('#excecoes-contador'), ' pendentes');
  if (!resultado.data.length) return;
  const { data } = resultado;

  const CFG = {
    sem_anexo:            ['ti-mail-off','Sem currículo','yellow'],
    formato_invalido:     ['ti-file-x','Formato inválido','red'],
    arquivo_corrompido:   ['ti-file-x','Sem leitura','red'],
    ocr_falhou:           ['ti-scan-off','OCR falhou','red'],
    docs_privado:         ['ti-lock','Docs privado','blue'],
    nao_e_curriculo:      ['ti-file-off','Não é currículo','yellow'],
    vaga_nao_identificada:['ti-help-circle','Vaga indefinida','blue'],
    erro_processamento:   ['ti-alert-triangle','Erro','red']
  };

  el.innerHTML = data.map(e => {
    const [ic, lbl, cor] = CFG[e.tipo] || ['ti-alert-triangle', e.tipo, 'gray'];
    return `<div class="exc-full">
      <div class="exc-icon-box pill-${cor}"><i class="ti ${ic}"></i></div>
      <div class="exc-info">
        <div class="exc-email">${escapeHtml(e.email_remetente)}</div>
        <div class="exc-meta">${tempoRelativo(e.recebido_em)} · ${escapeHtml(e.detalhe_erro || lbl)}</div>
      </div>
      <span class="pill pill-${cor}">${lbl}</span>
      <div class="exc-btns">
        <button class="btn-sm" onclick="resolverExcecao('${e.id}','revisado')">Revisar</button>
        <button class="btn-sm" onclick="resolverExcecao('${e.id}','ignorado')">Ignorar</button>
      </div>
    </div>`;
  }).join('');
}

async function resolverExcecao(id, status) {
  const { error } = await db.from('excecoes').update({
    status, revisado_em: new Date().toISOString(), revisado_por: app.usuario.id
  }).eq('id', id);
  if (error) { toast(error.message, 'erro'); return; }
  toast(status === 'revisado' ? 'Marcado como revisado' : 'Item ignorado');
  carregarExcecoes();
}

function trocarAba(aba, el) {
  $$('.tab').forEach(t => t.classList.remove('active'));
  el.classList.add('active');
  deslizarPilula($('#tabs-pilula'), el, 'x');
  $$('.sub-screen').forEach(s => s.classList.remove('active'));
  $('#sub-' + aba).classList.add('active');
  if (aba === 'excecoes') carregarExcecoes();
  else carregarVagas();
}


