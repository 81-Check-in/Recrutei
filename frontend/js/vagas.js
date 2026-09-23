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
    // Reprocessamento já pedido: mostra o selo em vez do botão, pra não pedir duas vezes
    // (a rotina do backend limpa reprocessar_solicitado_em quando termina a tentativa).
    const botaoReprocessar = e.reprocessar_solicitado_em
      ? `<span class="pill pill-blue" title="Pedido ${tempoRelativo(e.reprocessar_solicitado_em)} — a rotina tenta na próxima execução">
           <i class="ti ti-clock"></i>Reprocessamento pedido</span>`
      : `<button class="btn-sm" onclick="reprocessarExcecao('${e.id}', this)" title="Busca o e-mail original de novo e tenta classificar/avaliar mais uma vez">
           <i class="ti ti-refresh"></i>Reprocessar</button>`;
    return `<div class="exc-full">
      <div class="exc-icon-box pill-${cor}"><i class="ti ${ic}"></i></div>
      <div class="exc-info">
        <div class="exc-email">${escapeHtml(e.email_remetente)}</div>
        <div class="exc-meta">${tempoRelativo(e.recebido_em)} · ${escapeHtml(e.detalhe_erro || lbl)}</div>
      </div>
      <span class="pill pill-${cor}">${lbl}</span>
      <div class="exc-btns">
        <button class="btn-sm" onclick="verEmailExcecao('${e.id}')" title="Ver o e-mail original">
          <i class="ti ti-mail"></i>Ver e-mail</button>
        ${botaoReprocessar}
        <button class="btn-sm" onclick="resolverExcecao('${e.id}','revisado')">Revisar</button>
        <button class="btn-sm" onclick="resolverExcecao('${e.id}','ignorado')">Ignorar</button>
      </div>
    </div>`;
  }).join('');
}

// Escapa primeiro, SEMPRE — só depois marca URLs como link. Nessa ordem, o texto
// capturado pelo regex nunca contém aspas cruas (já viraram &quot;), então não tem
// como "fechar" o atributo href e injetar outra coisa na tag — mesmo que o e-mail
// (conteúdo de terceiros, não confiável) tente. Ver teste em xss2.js desta sessão.
function linkificar(textoEscapado) {
  return textoEscapado.replace(/https?:\/\/[^\s<]+/g,
    url => `<a href="${url}" target="_blank" rel="noopener noreferrer">${url}</a>`);
}

async function verEmailExcecao(id) {
  const { data, error } = await db.from('excecoes')
    .select('email_remetente,email_assunto,email_corpo,texto_extraido,recebido_em')
    .eq('id', id).single();
  if (error) { toast(error.message, 'erro'); return; }

  $('#ve-remetente').textContent = data.email_remetente || '—';
  $('#ve-assunto').textContent = data.email_assunto || '(sem assunto)';
  $('#ve-data').textContent = fmtDataHora(data.recebido_em);

  const temCorpo = (data.email_corpo || '').trim();
  const temTexto = (data.texto_extraido || '').trim();
  $('#ve-corpo').innerHTML = temCorpo ? linkificar(escapeHtml(data.email_corpo)) : '<span class="sem-dados">Corpo vazio</span>';
  $('#ve-sec-texto').style.display = temTexto ? 'block' : 'none';
  if (temTexto) $('#ve-texto').innerHTML = linkificar(escapeHtml(data.texto_extraido));
  $('#ve-vazio').style.display = (!temCorpo && !temTexto) ? 'block' : 'none';

  abrirModal('modal-ver-email');
}

async function resolverExcecao(id, status) {
  const { error } = await db.from('excecoes').update({
    status, revisado_em: new Date().toISOString(), revisado_por: app.usuario.id
  }).eq('id', id);
  if (error) { toast(error.message, 'erro'); return; }
  toast(status === 'revisado' ? 'Marcado como revisado' : 'Item ignorado');
  carregarExcecoes();
}

// Só marca o pedido — quem busca o e-mail de novo e tenta classificar/avaliar é o
// pipeline Python (backend/pipeline.py, reprocessar_excecoes()), na próxima execução
// (diária, ou python main.py --reprocessar-excecoes). Precisa de backend/sql/017_
// reprocessar_excecoes.sql já aplicado — sem isso a coluna não existe e o PostgREST
// devolve PGRST204 (confirmado direto na API; NÃO é 42703, que é o código do Postgres
// puro — o PostgREST tem sua própria tabela de códigos).
async function reprocessarExcecao(id, btn) {
  if (btn) { btn.disabled = true; btn.innerHTML = '<i class="ti ti-loader-2 girando"></i>Pedindo…'; }
  const { error } = await db.from('excecoes').update({
    reprocessar_solicitado_em: new Date().toISOString(), reprocessar_solicitado_por: app.usuario.id
  }).eq('id', id);
  if (error) {
    toast(error.code === 'PGRST204' || /schema cache/.test(error.message)
      ? 'Reprocessar ainda não habilitado no banco. Rode backend/sql/017_reprocessar_excecoes.sql.'
      : error.message, 'erro');
    if (btn) { btn.disabled = false; btn.innerHTML = '<i class="ti ti-refresh"></i>Reprocessar'; }
    return;
  }
  toast('Reprocessamento pedido — a rotina tenta na próxima execução');
  carregarExcecoes();
}

// Mesma ideia do reprocessarExcecao(), mas em massa: marca todas as pendentes que
// ainda não têm pedido em aberto (pra não reiniciar a contagem de quem já está na fila).
async function reprocessarTudo() {
  if (!estadoExcecoes.total) return;
  if (!await confirmar({
    titulo: 'Reprocessar tudo', rotulo: 'Reprocessar', perigo: false,
    mensagem: `Pedir reprocessamento de todas as exceções pendentes (${estadoExcecoes.total})?\n\nA rotina tenta cada uma na próxima execução.`
  })) return;

  const btn = $('#btn-reprocessar-tudo');
  if (btn) { btn.disabled = true; btn.innerHTML = '<i class="ti ti-loader-2 girando"></i>Pedindo…'; }

  const { error } = await db.from('excecoes').update({
    reprocessar_solicitado_em: new Date().toISOString(), reprocessar_solicitado_por: app.usuario.id
  }).eq('status', 'pendente').is('reprocessar_solicitado_em', null);

  if (btn) { btn.disabled = false; btn.innerHTML = '<i class="ti ti-refresh"></i>Reprocessar tudo'; }

  if (error) {
    toast(error.code === 'PGRST204' || /schema cache/.test(error.message)
      ? 'Reprocessar ainda não habilitado no banco. Rode backend/sql/017_reprocessar_excecoes.sql.'
      : error.message, 'erro');
    return;
  }
  toast('Reprocessamento pedido para todas as exceções pendentes');
  carregarExcecoes();
}

// ── Upload manual de currículo ──
// Para currículo recebido fora do e-mail (WhatsApp, indicação, entrega em mão). O
// modal sobe o arquivo pro Storage e grava a fila (backend/sql/019_uploads_manuais.sql
// precisa estar aplicado — sem isso a tabela não existe). Com API_URL configurada
// (nucleo.js), chama backend/api.py na hora — a IA avalia e a resposta já volta com
// o resultado, sem esperar a próxima execução da rotina. Sem API_URL (ou se o serviço
// estiver fora do ar), cai no comportamento antigo: fica na fila normal, avaliado na
// próxima execução do pipeline Python (backend/pipeline.py, processar_uploads_manuais()).
const FORMATOS_UPLOAD_MANUAL = {
  'application/pdf': '.pdf',
  'application/vnd.openxmlformats-officedocument.wordprocessingml.document': '.docx',
  'application/msword': '.doc'
};
const TAMANHO_MAXIMO_UPLOAD_MANUAL = 10 * 1024 * 1024;   // mesmo limite do backend (config.TAMANHO_MAXIMO_ANEXO)

async function abrirModalUploadManual() {
  $('#up-arquivo').value = '';
  $('#up-vaga').innerHTML = '<option value="">Carregando vagas…</option>';
  abrirModal('modal-upload-manual');

  const { data, error } = await db.from('vw_vagas_resumo').select('id,titulo,setor_nome').order('titulo');
  $('#up-vaga').innerHTML = error
    ? '<option value="">Não foi possível carregar as vagas</option>'
    : (data.length ? '<option value="">Escolha a vaga…</option>' : '<option value="">Nenhuma vaga aberta</option>')
      + data.map(v => `<option value="${v.id}">${escapeHtml(rotuloVaga(v))}</option>`).join('');

  carregarUploadsManuais();
}

async function enviarUploadManual() {
  const vagaId = $('#up-vaga').value;
  const arquivo = $('#up-arquivo').files[0];
  if (!vagaId) { toast('Escolha a vaga', 'erro'); return; }
  if (!arquivo) { toast('Escolha um arquivo', 'erro'); return; }
  const ext = FORMATOS_UPLOAD_MANUAL[arquivo.type];
  if (!ext) { toast('Formato não aceito — envie PDF, DOC ou DOCX', 'erro'); return; }
  if (arquivo.size > TAMANHO_MAXIMO_UPLOAD_MANUAL) { toast('Arquivo maior que 10 MB', 'erro'); return; }

  const btn = $('#up-btn-enviar');
  btn.disabled = true; btn.innerHTML = '<i class="ti ti-loader-2 girando"></i>Enviando…';

  const caminho = `manual/${new Date().getFullYear()}/${crypto.randomUUID()}${ext}`;
  const { error: erroUpload } = await db.storage.from('curriculos')
    .upload(caminho, arquivo, { contentType: arquivo.type, upsert: false });

  if (erroUpload) {
    toast(erroUpload.message, 'erro');
    btn.disabled = false; btn.innerHTML = '<i class="ti ti-send"></i>Enviar para avaliação';
    return;
  }

  const { data: registro, error } = await db.from('uploads_manuais').insert({
    vaga_id: vagaId,
    nome_arquivo: arquivo.name,
    tipo_mime: arquivo.type,
    tamanho_bytes: arquivo.size,
    storage_path: caminho,
    enviado_por: app.usuario.id
  }).select('id').single();

  if (error) {
    btn.disabled = false; btn.innerHTML = '<i class="ti ti-send"></i>Enviar para avaliação';
    toast(error.code === 'PGRST205' || /schema cache/.test(error.message)
      ? 'Envio manual ainda não habilitado no banco. Rode backend/sql/019_uploads_manuais.sql.'
      : error.message, 'erro');
    return;
  }

  $('#up-arquivo').value = '';

  if (!API_URL) {
    btn.disabled = false; btn.innerHTML = '<i class="ti ti-send"></i>Enviar para avaliação';
    toast('Currículo enviado — a IA avalia na próxima execução da rotina');
    carregarUploadsManuais();
    return;
  }

  btn.innerHTML = '<i class="ti ti-loader-2 girando"></i>Avaliando…';
  await avaliarUploadAgora(registro.id);
  btn.disabled = false; btn.innerHTML = '<i class="ti ti-send"></i>Enviar para avaliação';
  carregarUploadsManuais();
}

// Chama backend/api.py pra avaliar na hora. Se o serviço estiver fora do ar (ou
// API_URL não configurada), o currículo já está gravado na fila — a rotina agendada
// processa depois, então aqui só avisamos que vai demorar mais, sem tratar como erro.
async function avaliarUploadAgora(uploadId) {
  const { data: { session } } = await db.auth.getSession();
  if (!session) { toast('Currículo enviado — a IA avalia na próxima execução da rotina'); return; }

  let resp;
  try {
    resp = await fetch(`${API_URL}/uploads-manuais/${uploadId}/avaliar`, {
      method: 'POST',
      headers: { Authorization: `Bearer ${session.access_token}` }
    });
  } catch {
    toast('Currículo enviado — avaliação imediata indisponível agora, entra na fila normal');
    return;
  }

  if (!resp.ok) {
    toast('Currículo enviado — avaliação imediata falhou, entra na fila normal', 'erro');
    return;
  }

  const resultado = await resp.json();
  if (resultado.status === 'erro') {
    toast(resultado.detalhe_erro || 'Não foi possível avaliar este currículo', 'erro');
    return;
  }
  if (resultado.status === 'processado' && resultado.candidatura_gerada_id) {
    const { data: c } = await db.from('vw_triagem').select('nome,nota')
      .eq('id', resultado.candidatura_gerada_id).single();
    toast(c?.nota != null ? `Avaliado — ${c.nome || 'candidato'} (nota ${c.nota})` : 'Currículo avaliado');
    return;
  }
  toast('Currículo enviado — a IA avalia na próxima execução da rotina');
}

async function carregarUploadsManuais() {
  const el = $('#up-lista');
  el.innerHTML = '<p class="sem-dados">Carregando…</p>';

  const { data, error } = await db.from('uploads_manuais')
    .select('id,nome_arquivo,status,detalhe_erro,enviado_em,vagas(titulo)')
    .order('enviado_em', { ascending: false }).limit(8);

  if (error) { el.innerHTML = ''; return; }   // tabela pode não existir ainda — não trava o modal
  if (!data.length) { el.innerHTML = '<p class="sem-dados">Nenhum envio ainda</p>'; return; }

  const CFG = {
    pendente:   ['ti-clock', 'Pendente', 'yellow'],
    processado: ['ti-circle-check', 'Processado', 'green'],
    erro:       ['ti-alert-triangle', 'Falhou', 'red']
  };
  el.innerHTML = data.map(u => {
    const [ic, lbl, cor] = CFG[u.status] || ['ti-file', u.status, 'gray'];
    const detalhe = u.status === 'erro' && u.detalhe_erro ? ' · ' + escapeHtml(u.detalhe_erro) : '';
    return `<div class="exc-full" style="padding:10px 12px">
      <div class="exc-icon-box pill-${cor}"><i class="ti ${ic}"></i></div>
      <div class="exc-info">
        <div class="exc-email">${escapeHtml(u.nome_arquivo)}</div>
        <div class="exc-meta">${escapeHtml((u.vagas || {}).titulo || '—')} · ${tempoRelativo(u.enviado_em)}${detalhe}</div>
      </div>
      <span class="pill pill-${cor}"><i class="ti ${ic}"></i>${lbl}</span>
    </div>`;
  }).join('');
}

function trocarAba(aba, el) {
  $$('.tab').forEach(t => t.classList.remove('active'));
  el.classList.add('active');
  deslizarPilula($('#tabs-pilula'), el, 'x');
  $$('.sub-screen').forEach(s => s.classList.remove('active'));
  $('#sub-' + aba).classList.add('active');
  $('#btn-reprocessar-tudo').style.display = aba === 'excecoes' ? 'flex' : 'none';
  if (aba === 'excecoes') carregarExcecoes();
  else carregarVagas();
}


