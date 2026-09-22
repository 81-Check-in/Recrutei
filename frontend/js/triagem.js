// ═══════════════════════════════════════════════════════════
//  TRIAGEM DE CURRÍCULOS
// ═══════════════════════════════════════════════════════════

const estadoTriagem = novoEstadoLista(50);

// ── Filtros avançados (palavras-chave, localização, idade, escolaridade, experiência,
// CNH, rotatividade) — usam a função filtrar_triagem() do banco (backend/sql/filtros_avancados.sql).
// null = nenhum filtro avançado ativo; a tela usa a consulta simples de sempre.
let filtrosAvancados = null;

function alternarFiltrosAvancados() {
  const painel = $('#painel-filtros-av');
  const abrir = painel.style.display === 'none';
  painel.style.display = abrir ? 'block' : 'none';
  $('#btn-filtros-av').setAttribute('aria-expanded', String(abrir));
}

// Só entra no objeto o que a pessoa preencheu — a função no banco trata ausência como
// "sem filtro". Devolve também quantos campos estão ativos, para o selo no botão.
function lerFiltrosAvancados() {
  const filtros = {};
  let ativos = 0;

  const palavras = $('#av-palavras').value.split(',').map(p => p.trim()).filter(Boolean);
  if (palavras.length) {
    filtros.palavras = palavras;
    filtros.palavras_modo = $('#av-palavras-modo').value;
    filtros.palavras_onde = $('#av-palavras-onde').value;
    ativos++;
  }

  const local = $('#av-local').value.trim();
  if (local) { filtros.local = local; ativos++; }

  const excluirLocais = $('#av-excluir-locais').value.split(',').map(p => p.trim()).filter(Boolean);
  if (excluirLocais.length) { filtros.excluir_locais = excluirLocais; ativos++; }

  const idadeMin = $('#av-idade-min').value.trim();
  const idadeMax = $('#av-idade-max').value.trim();
  if (idadeMin) { filtros.idade_min = Number(idadeMin); ativos++; }
  if (idadeMax) { filtros.idade_max = Number(idadeMax); ativos++; }

  const escolaridade = $('#av-escolaridade').value;
  if (escolaridade) { filtros.escolaridade_min = escolaridade; ativos++; }

  const experiencia = $('#av-experiencia').value.trim();
  if (experiencia) { filtros.experiencia_min = Number(experiencia); ativos++; }

  if ($('#av-cnh').checked) { filtros.cnh = true; ativos++; }

  const rotatividade = $('#av-rotatividade').value;
  if (rotatividade) { filtros.rotatividade = rotatividade; ativos++; }

  if (!$('#av-sem-info').checked) { filtros.incluir_sem_info = false; ativos++; }   // padrão é true

  return { filtros, ativos };
}

function atualizarBadgeFiltrosAv(ativos) {
  const badge = $('#badge-filtros-av');
  badge.style.display = ativos ? 'inline-flex' : 'none';
  badge.textContent = ativos;
  $('#btn-filtros-av').classList.toggle('ativo', ativos > 0);
}

function aplicarFiltrosAvancados() {
  const { filtros, ativos } = lerFiltrosAvancados();
  filtrosAvancados = ativos ? filtros : null;
  atualizarBadgeFiltrosAv(ativos);
  toast(ativos ? `${ativos} filtro${ativos > 1 ? 's' : ''} avançado${ativos > 1 ? 's' : ''} aplicado${ativos > 1 ? 's' : ''}`
               : 'Nenhum filtro avançado preenchido');
  carregarTriagem();
}

function limparFiltrosAvancados() {
  ['av-palavras', 'av-local', 'av-excluir-locais', 'av-idade-min', 'av-idade-max', 'av-experiencia']
    .forEach(id => { $('#' + id).value = ''; });
  $('#av-palavras-modo').value = 'todas';
  $('#av-palavras-onde').value = 'curriculo';
  $('#av-escolaridade').value = '';
  $('#av-rotatividade').value = '';
  $('#av-cnh').checked = false;
  $('#av-sem-info').checked = true;
  filtrosAvancados = null;
  atualizarBadgeFiltrosAv(0);
  carregarTriagem();
}

function maisTriagem() {
  const btn = $('#triagem-mais');
  if (btn) { btn.disabled = true; btn.innerHTML = '<i class="ti ti-loader-2 girando"></i>Carregando…'; }
  estadoTriagem.limite += estadoTriagem.tamanhoPagina;
  carregarTriagem();
}

async function carregarTriagem() {
  const el = $('#triagem-lista');

  // Popula filtro de vagas uma vez
  if (!$('#filtro-vaga').dataset.carregado) {
    const { data: vagas } = await db.from('vw_vagas_resumo').select('id,titulo').order('titulo');
    $('#filtro-vaga').innerHTML = '<option value="">Todas as vagas</option>' +
      (vagas || []).map(v => `<option value="${v.id}">${escapeHtml(v.titulo)}</option>`).join('');
    $('#filtro-vaga').dataset.carregado = '1';
  }

  const vaga   = $('#filtro-vaga').value;
  const faixa  = $('#filtro-nota').value;
  const status = $('#filtro-status').value;
  const busca  = $('#busca-triagem').value.trim();

  // Filtro mudou desde a última carga (inclui os avançados): volta para a primeira página
  paginaInicialSeFiltroMudou(estadoTriagem, JSON.stringify([vaga, faixa, status, busca, filtrosAvancados]));

  const montar = () => {
    // Com filtro avançado, a busca parte da função filtrar_triagem() em vez da view direto;
    // ela devolve as mesmas colunas, então os filtros comuns encaixam do mesmo jeito por cima.
    let q = filtrosAvancados
      ? db.rpc('filtrar_triagem', { filtros: filtrosAvancados }, { count: 'exact' })
      : db.from('vw_triagem').select('*', { count: 'exact' });
    if (vaga)   q = q.eq('vaga_id', vaga);
    if (status) q = q.eq('status', status);
    if (faixa === 'alta')  q = q.gte('nota', 76);
    if (faixa === 'media') q = q.gte('nota', 51).lte('nota', 75);
    if (faixa === 'baixa') q = q.lte('nota', 50);
    if (busca)  q = q.ilike('nome', `%${busca}%`);
    return q.order('nota', { ascending: false, nullsFirst: false })
             .order('recebido_em', { ascending: false });
  };

  const resultado = await carregarLista(el, estadoTriagem, montar,
    { icone: 'ti-files', msg: 'Nenhum currículo encontrado',
      sub: 'Os currículos aparecem aqui após o processamento diário dos e-mails',
      // PGRST202 = a função filtrar_triagem ainda não existe no banco
      mensagemErro: error => error.code === 'PGRST202'
        ? 'Filtros avançados ainda não habilitados no banco. Rode backend/sql/filtros_avancados.sql.'
        : error.message });

  if (!resultado) { destravarBotaoMais($('#triagem-mais')); return; }   // erro() já foi desenhado

  atualizarPaginacao($('#triagem-mais'), estadoTriagem, $('#triagem-total'), ' currículos');
  if (!resultado.data.length) return;
  const { data } = resultado;

  const STATUS_PILL = {
    recebido:            ['pill-gray','Recebido'],
    em_analise:          ['pill-blue','Em análise'],
    avaliado:            ['pill-blue','Aguardando'],
    selecionado:         ['pill-green','Selecionado'],
    entrevista_agendada: ['pill-blue','Entrevista agendada'],
    entrevista_realizada:['pill-blue','Entrevistado'],
    aprovado:            ['pill-green','Aprovado'],
    reprovado:           ['pill-red','Reprovado'],
    nao_compareceu:      ['pill-purple','Não compareceu'],
    contratado:          ['pill-green','Contratado'],
    descartado:          ['pill-red','Descartado']
  };

  el.innerHTML = data.map(c => {
    const [cls, lbl] = STATUS_PILL[c.status] || ['pill-gray', c.status];
    // Em análise = a IA ainda vai avaliar (ex.: o RH trocou a vaga); a nota guardada é da vaga anterior
    const pendente = c.status === 'em_analise';
    const alerta = c.divergencia_detectada && !pendente
      ? '<span class="pill pill-yellow" title="Avaliações divergentes">⚠ Revisar</span>' : '';
    const reinc = c.e_reincidente
      ? `<span class="tag-mini" title="${c.total_envios} envios">↻ ${c.total_envios}</span>` : '';
    const elim = c.eliminado_por_regra && !pendente
      ? '<span class="tag-mini vermelho" title="Não atende requisito obrigatório">Fora do perfil</span>' : '';

    return `<div class="curr-card" onclick="abrirAnalise('${c.id}')">
      <div class="nota-badge ${pendente ? 'nota-vazia' : classeNota(c.nota)}">${pendente ? '…' : (c.nota ?? '—')}</div>
      <div class="curr-ini">${iniciais(c.nome)}</div>
      <div class="curr-info">
        <div class="curr-nome">${escapeHtml(c.nome || 'Nome não extraído')} ${reinc} ${elim}</div>
        <div class="curr-resumo">${escapeHtml(pendente ? 'Avaliação pendente: a IA avalia o currículo para esta vaga na próxima execução'
          : (c.resumo_nota || c.resumo_ia || 'Aguardando avaliação da IA'))}</div>
        <div class="curr-meta">
          <span><i class="ti ti-briefcase"></i>${escapeHtml(c.vaga_titulo || 'Vaga não identificada')}${c.vaga_confirmada_rh ? ' <i class="ti ti-user-check" title="Vaga definida pelo RH" aria-label="Vaga definida pelo RH"></i>' : ''}</span>
          <span><i class="ti ti-calendar"></i>${tempoRelativo(c.recebido_em)}</span>
          ${c.telefone ? `<span><i class="ti ti-phone"></i>${escapeHtml(c.telefone)}</span>` : ''}
          ${c.aderencia_vaga != null ? `<span><i class="ti ti-target"></i>${c.aderencia_vaga}% aderência</span>` : ''}
        </div>
      </div>
      <div class="curr-acoes">${alerta}<span class="pill ${cls}">${lbl}</span></div>
    </div>`;
  }).join('');
}

// ── Painel de análise ──
async function abrirAnalise(id) {
  const { data: c, error } = await db.from('vw_triagem').select('*').eq('id', id).single();
  if (error) { toast('Erro ao carregar candidato', 'erro'); return; }

  app.candidatoAberto = c;

  $('#d-nome').textContent = c.nome || 'Nome não extraído';
  $('#d-sub').textContent  = `${c.vaga_titulo || 'Vaga não identificada'} · ${tempoRelativo(c.recebido_em)}`;

  // Em análise: a nota e os textos guardados são da vaga anterior, então não aparecem
  const pendente = c.status === 'em_analise';
  const av = pendente ? {} : c;

  const nc = $('#d-nota');
  nc.textContent = pendente ? '…' : (c.nota ?? '—');
  nc.className = 'nota-circulo ' + (pendente ? 'nota-vazia' : classeNota(c.nota));
  $('#d-nota-txt').textContent = pendente
    ? 'Avaliação pendente: a IA avalia o currículo para esta vaga na próxima execução.'
    : (c.resumo_nota || 'Avaliação ainda não realizada.');

  $('#d-dados').innerHTML = `
    <div class="dado"><div class="dado-lbl">Telefone</div><div class="dado-val">${escapeHtml(c.telefone||'—')}</div></div>
    <div class="dado"><div class="dado-lbl">E-mail</div><div class="dado-val">${escapeHtml(c.email||'—')}</div></div>
    <div class="dado"><div class="dado-lbl">Cidade</div><div class="dado-val">${escapeHtml(c.cidade||'—')}</div></div>
    <div class="dado"><div class="dado-lbl">Setor</div><div class="dado-val">${escapeHtml(c.setor_nome||'—')}</div></div>`;

  $('#d-fortes').innerHTML = (av.pontos_fortes||[]).length
    ? av.pontos_fortes.map(f => `<span class="tag verde">${escapeHtml(f)}</span>`).join('')
    : `<span class="sem-dados">${pendente ? 'Aguardando avaliação' : 'Nenhum ponto forte registrado'}</span>`;

  $('#d-lacunas').innerHTML = (av.lacunas||[]).length
    ? av.lacunas.map(l => `<span class="tag vermelha">${escapeHtml(l)}</span>`).join('')
    : `<span class="sem-dados">${pendente ? 'Aguardando avaliação' : 'Nenhuma lacuna registrada'}</span>`;

  const secFalt = $('#d-sec-faltantes');
  if ((av.requisitos_faltantes||[]).length) {
    secFalt.style.display = 'block';
    $('#d-faltantes').innerHTML = av.requisitos_faltantes
      .map(r => `<span class="tag vermelha">${escapeHtml(r)}</span>`).join('');
  } else secFalt.style.display = 'none';

  $('#d-resumo').textContent = av.resumo_ia || (pendente ? 'Aguardando a avaliação da IA.' : 'Resumo ainda não gerado pela IA.');

  // Ações conforme o status
  const jaSelecionado = ['selecionado','entrevista_agendada','entrevista_realizada',
                         'aprovado','reprovado','nao_compareceu','contratado'].includes(c.status);
  // Só se chama para entrevista depois da nota: a reavaliação pendente ficaria sem efeito
  $('#d-btn-chamar').style.display   = (jaSelecionado || pendente) ? 'none' : 'flex';
  $('#d-btn-descartar').style.display = (c.status === 'descartado') ? 'none' : 'flex';
  $('#d-btn-agendar').style.display  = jaSelecionado ? 'flex' : 'none';

  $('#d-btn-curriculo').style.display = c.storage_path ? 'flex' : 'none';
  $('#d-sem-arquivo').style.display   = c.storage_path ? 'none' : 'block';

  $('#drawer').classList.add('show');
  $('#drawer-overlay').classList.add('show');
  preencherTrocaVaga(c);
}

// ── Trocar a vaga: a IA avalia o mesmo currículo para outro setor ──
const STATUS_TROCA_VAGA = ['recebido', 'em_analise', 'avaliado'];   // depois de chamar, a vaga não muda

function rotuloVaga(v) {
  const setor = (v.setor_nome || '').trim();
  return setor && setor.toLowerCase() !== (v.titulo || '').trim().toLowerCase()
    ? `${v.titulo} — ${setor}` : v.titulo;
}

async function preencherTrocaVaga(c) {
  const sec = $('#d-sec-troca');
  const disponivel = STATUS_TROCA_VAGA.includes(c.status);
  sec.style.display = disponivel ? 'block' : 'none';
  if (!disponivel) return;

  $('#d-vaga-troca').innerHTML = '<option value="">Carregando vagas…</option>';
  $('#d-troca-ajuda').textContent = c.status === 'em_analise'
    ? 'Avaliação pendente. Escolher outra vaga troca a avaliação que a IA vai fazer.'
    : 'A IA avalia o mesmo currículo para a vaga escolhida e a nota nova substitui a atual. Isso acontece na próxima execução da rotina.';

  const { data, error } = await db.from('vw_vagas_resumo').select('id,titulo,setor_nome').order('titulo');
  if (app.candidatoAberto?.id !== c.id) return;          // outro candidato foi aberto enquanto carregava
  if (error) { $('#d-vaga-troca').innerHTML = '<option value="">Não foi possível carregar as vagas</option>'; return; }

  $('#d-vaga-troca').innerHTML = (c.vaga_id ? '' : '<option value="">Escolha a vaga…</option>') +
    (data || []).map(v =>
      `<option value="${v.id}"${v.id === c.vaga_id ? ' selected' : ''}>${escapeHtml(rotuloVaga(v))}</option>`).join('');
}

async function trocarVagaCandidato() {
  const c = app.candidatoAberto;
  const sel = $('#d-vaga-troca');
  const vagaId = sel.value;
  if (!c || !STATUS_TROCA_VAGA.includes(c.status)) return;
  if (!vagaId || vagaId === c.vaga_id) { toast('Escolha uma vaga diferente da atual', 'erro'); return; }

  const rotuloVagaEscolhida = sel.selectedOptions[0].textContent;
  if (!await confirmar({
    titulo: 'Trocar vaga avaliada', rotulo: 'Reavaliar', perigo: false,
    mensagem: `Avaliar ${c.nome || 'este candidato'} para a vaga "${rotuloVagaEscolhida}"?\n\n` +
              'A nota atual deixa de valer e a IA avalia o currículo de novo na próxima execução.'
  })) return;

  const btn = $('#d-btn-trocar');
  btn.disabled = true;
  const { data, error } = await db.from('candidaturas').update({
    vaga_id: vagaId,
    status: 'em_analise',        // a rotina reavalia tudo o que estiver em análise
    aderencia_vaga: null,        // a aderência era da vaga anterior
    vaga_confirmada_rh: true
  }).eq('id', c.id).select('id');
  btn.disabled = false;

  if (error) { toast(error.message, 'erro'); return; }
  if (!data?.length) { toast('Não foi possível trocar a vaga (sem permissão)', 'erro'); return; }

  fecharDrawer();
  toast('Vaga alterada. A IA reavalia o currículo na próxima execução');
  carregarTriagem();
}

function fecharDrawer() {
  $('#drawer').classList.remove('show');
  $('#drawer-overlay').classList.remove('show');
}

// ── Abrir currículo original (URL assinada) ──
async function verCurriculo(candidaturaId) {
  const id = candidaturaId || app.candidatoAberto?.id;
  if (!id) return;

  const { data: cur, error } = await db.from('curriculos')
    .select('storage_path,nome_arquivo').eq('candidatura_id', id).single();

  if (error || !cur?.storage_path) {
    toast('Arquivo do currículo não disponível', 'erro'); return;
  }

  const { data, error: e2 } = await db.storage
    .from('curriculos').createSignedUrl(cur.storage_path, 3600);

  if (e2) { toast('Erro ao abrir currículo: ' + e2.message, 'erro'); return; }
  window.open(data.signedUrl, '_blank');
}

async function baixarCurriculo(candidaturaId) {
  const id = candidaturaId || app.candidatoAberto?.id;
  if (!id) return;

  const { data: cur } = await db.from('curriculos')
    .select('storage_path,nome_arquivo').eq('candidatura_id', id).single();

  if (!cur?.storage_path) { toast('Arquivo não disponível', 'erro'); return; }

  const { data, error } = await db.storage
    .from('curriculos').download(cur.storage_path);

  if (error) { toast('Erro ao baixar: ' + error.message, 'erro'); return; }

  const url = URL.createObjectURL(data);
  const a = document.createElement('a');
  a.href = url;
  a.download = cur.nome_arquivo || 'curriculo.pdf';
  a.click();
  URL.revokeObjectURL(url);
}

// ── Selecionar / descartar ──
async function selecionarCandidato() {
  const c = app.candidatoAberto;
  if (!c) return;

  const { error } = await db.from('candidaturas').update({
    status: 'selecionado',
    selecionado_em: new Date().toISOString(),
    selecionado_por: app.usuario.id
  }).eq('id', c.id);

  if (error) { toast(error.message, 'erro'); return; }

  fecharDrawer();
  toast(`${c.nome} agora é candidato`);
  abrirAgendamento(c.id, c.nome, c.telefone_e164 || c.telefone);
  carregarTriagem();
}

async function descartarCandidato() {
  const c = app.candidatoAberto;
  if (!c) return;

  const motivo = prompt('Motivo do descarte (opcional):');
  if (motivo === null) return;

  const { error } = await db.from('candidaturas').update({
    status: 'descartado',
    descartado_em: new Date().toISOString(),
    descartado_por: app.usuario.id,
    motivo_descarte: motivo || null
  }).eq('id', c.id);

  if (error) { toast(error.message, 'erro'); return; }

  fecharDrawer();
  toast('Currículo descartado');
  carregarTriagem();
}

