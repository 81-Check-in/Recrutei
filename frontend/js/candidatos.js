// ═══════════════════════════════════════════════════════════
//  EM PROCESSO — candidatos que o RH atribuiu a uma vaga (candidaturas)
//  Aqui se agenda a entrevista e se acompanha o resultado. Quem é reprovado ou tem a candidatura
//  cancelada volta sozinho ao Banco de Talentos; a candidatura antiga fica no histórico dele.
// ═══════════════════════════════════════════════════════════

const estadoCandidatos = novoEstadoLista(50);

// Modo "por vaga": o número de candidatos do card da vaga abre esta tela só com os selecionados para ela (mesma tabela, mais espaço
// para trabalhar: ver o currículo, agendar, cancelar a seleção). null = todos os candidatos em processo.
let vagaEmProcesso = null;        // { id, titulo, pronta }

function abrirCandidatosDaVaga(vagaId, titulo, pronta = true) {
  vagaEmProcesso = { id: vagaId, titulo, pronta };
  $('#busca-candidatos').value = '';
  $('#filtro-cand-status').value = '';
  estadoCandidatos.limite = estadoCandidatos.tamanhoPagina;
  irPara('candidatos');
}

function sairDaVagaEmProcesso() {
  vagaEmProcesso = null;
  irPara('vagas');
}

function selecionarMaisCVsDaVaga() {
  const v = vagaEmProcesso;
  if (v) verCandidatosDaVaga(v.id, v.titulo, v.pronta);
}

function atualizarModoVaga() {
  const ativo = !!vagaEmProcesso;
  $('#cand-vaga-banner').style.display = ativo ? 'flex' : 'none';
  $('#th-cand-vaga').textContent = ativo ? 'Qualificação' : 'Vaga';
  if (ativo) $('#cand-vaga-titulo').textContent = vagaEmProcesso.titulo || 'vaga';
}

// Candidaturas que ainda pedem uma entrevista marcada
const PRECISA_AGENDAR = ['aguardando', 'selecionado', 'nao_compareceu'];

function maisCandidatos() {
  const btn = $('#candidatos-mais');
  if (btn) { btn.disabled = true; btn.innerHTML = '<i class="ti ti-loader-2 girando"></i>Carregando…'; }
  estadoCandidatos.limite += estadoCandidatos.tamanhoPagina;
  return carregarCandidatos();
}

async function carregarCandidatos() {
  const el = $('#candidatos-body');

  const status = $('#filtro-cand-status').value;
  const busca  = $('#busca-candidatos').value.trim();
  atualizarModoVaga();
  paginaInicialSeFiltroMudou(estadoCandidatos, JSON.stringify([status, busca, vagaEmProcesso?.id || null]));

  if (estadoCandidatos.limite === estadoCandidatos.tamanhoPagina) {
    el.innerHTML = '<tr><td colspan="6"><div class="estado-vazio"><i class="ti ti-loader-2 girando"></i><p>Carregando...</p></div></td></tr>';
  }

  let q = db.from('vw_candidatos').select('*', { count: 'exact' });
  if (status === 'aguardando') q = q.in('status', ['aguardando', 'selecionado']);
  else if (status) q = q.eq('status', status);
  if (busca) q = q.ilike('nome', `%${busca}%`);
  if (vagaEmProcesso) q = q.eq('vaga_id', vagaEmProcesso.id);

  const versao = ++estadoCandidatos.versao;
  const { data, error, count } = await q
    .order('data_atribuicao', { ascending: false, nullsFirst: false }).limit(estadoCandidatos.limite);
  if (versao !== estadoCandidatos.versao) return;        // mudou o filtro enquanto esta consulta esperava: descarta a antiga

  if (error) {
    el.innerHTML = `<tr><td colspan="6"><div class="estado-vazio erro"><i class="ti ti-alert-triangle"></i><p>${escapeHtml(mensagemErro(error))}</p></div></td></tr>`;
    destravarBotaoMais($('#candidatos-mais'));
    return;
  }

  estadoCandidatos.total = count ?? data.length;
  atualizarPaginacao($('#candidatos-mais'), estadoCandidatos, $('#candidatos-contador'), ' candidaturas');

  if (!data.length) {
    el.innerHTML = vagaEmProcesso
      ? `<tr><td colspan="6"><div class="estado-vazio">
          <i class="ti ti-user-check"></i><p>Nenhum currículo selecionado para esta vaga</p>
          <span>Use "Selecionar CVs" para ver os currículos do Banco de Talentos com o setor, a função e o nível da vaga</span></div></td></tr>`
      : `<tr><td colspan="6"><div class="estado-vazio">
          <i class="ti ti-user-check"></i><p>Nenhum candidato em processo</p>
          <span>Atribua candidatos do Banco de Talentos a uma vaga para que apareçam aqui</span></div></td></tr>`;
    return;
  }

  el.innerHTML = data.map(c => {
    const [cls, lbl] = STATUS_CANDIDATURA[c.status] || ['pill-gray', c.status];
    const aberta = !c.encerrada_em;
    const precisaAgendar = PRECISA_AGENDAR.includes(c.status);
    const nota = c.nota_curriculo ?? c.nota;               // a nota que a IA deu ao currículo (não há mais avaliação da IA por vaga)
    const pillNota = nota == null ? 'pill-gray'
      : nota >= 76 ? 'pill-green' : nota >= 51 ? 'pill-yellow' : 'pill-red';
    const qualificacao = [c.area_sugerida, c.cargo_sugerido].filter(Boolean).join(' / ');
    return `<tr>
      <td><div class="cand-row">
        <div class="cand-av">${iniciais(c.nome)}</div>
        <div><div class="cand-nome">${escapeHtml(c.nome || '—')}</div>
             <div class="cand-tel">${escapeHtml(c.telefone || '—')}</div></div>
      </div></td>
      ${vagaEmProcesso
        ? `<td>${escapeHtml(qualificacao || '—')}<div class="cand-tel">${escapeHtml(rotuloNivel(c.nivel_sugerido))}</div></td>`
        : `<td>${escapeHtml(c.vaga_titulo || '—')}<div class="cand-tel">${escapeHtml(c.setor_nome || '')}</div></td>`}
      <td><span class="pill ${pillNota}">${nota ?? '—'}</span></td>
      <td>${fmtDataHora(c.data_atribuicao || c.selecionado_em)}</td>
      <td><span class="pill ${cls}">${lbl}</span></td>
      <td class="td-acoes">
        <button class="btn-sm" onclick="verCurriculo('${c.id}')" title="Ver currículo"><i class="ti ti-file-text"></i></button>
        <button class="btn-sm" onclick="abrirCandidatura('${c.id}')"><i class="ti ti-eye"></i>Ver</button>
        ${precisaAgendar
          ? `<button class="btn-sm azul" data-id="${c.id}" data-nome="${escapeHtml(c.nome)}" data-tel="${escapeHtml(c.telefone_e164 || '')}" onclick="abrirAgendamento(this.dataset.id, this.dataset.nome, this.dataset.tel)"><i class="ti ti-brand-whatsapp"></i>Agendar</button>`
          : ''}
        ${aberta
          ? `<button class="btn-sm vermelho" data-id="${c.id}" data-nome="${escapeHtml(c.nome || '')}" onclick="devolverAoBancoPorId(this.dataset.id, this.dataset.nome)" title="Cancelar a seleção: o candidato volta ao Banco de Talentos, com a qualificação que já tem"><i class="ti ti-arrow-back-up"></i>${vagaEmProcesso ? 'Cancelar seleção' : ''}</button>`
          : ''}
      </td>
    </tr>`;
  }).join('');
}

// ── Devolver ao Banco de Talentos / reprovar ──
// O banco cuida do resto: fecha a candidatura, cancela entrevista marcada e volta o candidato para "disponível".
async function encerrarCandidatura(id, status, motivo) {
  const { error } = await db.rpc('encerrar_candidatura', { p_candidatura_id: id, p_status: status, p_motivo: motivo || null });
  if (error) { toast(mensagemErro(error), 'erro'); return false; }
  return true;
}

function recarregarTelaDeCandidaturas() {
  const carregar = { candidatos: carregarCandidatos, entrevistas: carregarEntrevistas, banco: carregarBanco }[app.telaAtual];
  return carregar ? carregar() : Promise.resolve();
}

async function devolverAoBancoPorId(id, nome) {
  if (!await confirmar({
    titulo: 'Cancelar a seleção', rotulo: 'Cancelar seleção', perigo: false,
    mensagem: `Cancelar a seleção de ${nome || 'este candidato'}?\n\nO currículo volta ao Banco de Talentos, disponível para outra vaga, e mantém a ` +
              'qualificação (setor, função e nível) que já tem. O histórico desta candidatura fica guardado. Entrevista marcada é cancelada.'
  })) return;
  if (!await encerrarCandidatura(id, 'cancelado', 'Devolvido ao Banco de Talentos pelo RH')) return;
  fecharDrawer();
  toast(`${nome || 'Candidato'} voltou ao Banco de Talentos`);
  await recarregarTelaDeCandidaturas();
}

async function devolverAoBanco() {
  const c = app.candidatoAberto;
  if (c) await devolverAoBancoPorId(c.id, c.nome);
}

async function reprovarCandidatura() {
  const c = app.candidatoAberto;
  if (!c) return;
  const motivo = prompt(`Motivo da reprovação de ${c.nome || 'este candidato'} (opcional):`);
  if (motivo === null) return;
  if (!await encerrarCandidatura(c.id, 'reprovado', motivo.trim())) return;
  fecharDrawer();
  toast(`${c.nome || 'Candidato'} reprovado — volta ao Banco de Talentos`);
  await recarregarTelaDeCandidaturas();
}

// ═══════════════════════════════════════════════════════════
//  DRAWER DA CANDIDATURA — a nota da IA para aquela vaga
// ═══════════════════════════════════════════════════════════
async function abrirCandidatura(id) {
  const { data: c, error } = await db.from('vw_candidaturas').select('*').eq('id', id).single();
  if (error) { toast('Erro ao carregar candidatura: ' + mensagemErro(error), 'erro'); return; }

  app.candidatoAberto = c;
  const [, lblStatus] = STATUS_CANDIDATURA[c.status] || ['', c.status];

  $('#d-nome').textContent = c.nome || 'Nome não extraído';
  $('#d-sub').textContent  = `${c.vaga_titulo || 'Vaga removida'} · ${lblStatus} · atribuído ${tempoRelativo(c.data_atribuicao || c.recebido_em)}` +
    (c.atribuido_por_nome ? ` por ${c.atribuido_por_nome}` : '');

  // Avaliação pendente: a IA ainda vai avaliar o candidato para esta vaga
  const pendente = c.avaliacao_pendente;
  const av = pendente ? {} : c;

  const nc = $('#d-nota');
  const notaCv = c.nota ?? c.nota_curriculo;                 // nota da avaliação antiga por vaga, ou a que a IA deu ao currículo
  nc.textContent = pendente ? '…' : (notaCv ?? '—');
  nc.className = 'nota-circulo ' + (pendente ? 'nota-vazia' : classeNota(notaCv));
  $('#d-nota-txt').textContent = pendente
    ? 'Avaliação pendente: a IA avalia o currículo para esta vaga na próxima execução.'
    : (c.resumo_nota || (notaCv != null
        ? 'Nota que a IA deu ao currículo. Na vaga não há avaliação da IA: os currículos são selecionados pelo setor, função e nível.'
        : 'Currículo ainda sem nota da IA.'));

  $('#d-sec-resultado').style.display = c.encerrada_em ? 'block' : 'none';
  if (c.encerrada_em) $('#d-resultado').textContent = `${c.resultado_final || 'Encerrada'} (em ${fmtData(c.encerrada_em)})`;

  const sugestao = [c.area_sugerida, c.cargo_sugerido, rotuloNivel(c.nivel_sugerido)].filter(Boolean).join(' / ');
  $('#d-dados').innerHTML = [
    ['Telefone', c.telefone], ['E-mail', c.email], ['Mora em', rotuloLocal(c) === '—' ? '' : rotuloLocal(c)],
    ['Setor da vaga', c.setor_nome], ['Sexo', c.sexo === 'masculino' ? 'Masculino' : c.sexo === 'feminino' ? 'Feminino' : ''],
    ['Sugestão da IA', sugestao]
  ].map(([r, v]) =>
    `<div class="dado"><div class="dado-lbl">${r}</div><div class="dado-val">${escapeHtml(v || '—')}</div></div>`).join('');

  $('#d-fortes').innerHTML = htmlTags(av.pontos_fortes, 'verde', pendente ? 'Aguardando avaliação' : 'Nenhum ponto forte registrado');
  $('#d-lacunas').innerHTML = htmlTags(av.lacunas, 'vermelha', pendente ? 'Aguardando avaliação' : 'Nenhuma lacuna registrada');

  const secFalt = $('#d-sec-faltantes');
  if ((av.requisitos_faltantes || []).length) {
    secFalt.style.display = 'block';
    $('#d-faltantes').innerHTML = av.requisitos_faltantes.map(r => `<span class="tag vermelha">${escapeHtml(r)}</span>`).join('');
  } else secFalt.style.display = 'none';

  $('#d-resumo').textContent = av.resumo_ia || (pendente ? 'Aguardando a avaliação da IA.' : 'Resumo ainda não gerado pela IA.');

  const aberta = !c.encerrada_em;
  $('#d-btn-devolver').style.display  = aberta ? 'flex' : 'none';
  $('#d-btn-reprovar').style.display  = aberta ? 'flex' : 'none';
  $('#d-btn-agendar').style.display   = PRECISA_AGENDAR.includes(c.status) && aberta ? 'flex' : 'none';
  $('#d-btn-curriculo').style.display = c.storage_path ? 'flex' : 'none';
  $('#d-sem-arquivo').style.display   = c.storage_path ? 'none' : 'flex';

  mostrarConsideracoes('d', c.candidato_id);
  $('#drawer').classList.add('show');
  $('#drawer-overlay').classList.add('show');
}

function abrirTalentoDaCandidatura() {
  const id = app.candidatoAberto?.candidato_id;
  if (!id) return;
  fecharDrawer();
  abrirTalento(id);
}

// ── Currículo pela candidatura (usado na agenda de entrevistas e aqui) ──
async function dadosDoCurriculoDaCandidatura(candidaturaId) {
  const id = candidaturaId || app.candidatoAberto?.id;
  if (!id) return null;
  const { data } = await db.from('vw_candidaturas').select('storage_path,nome_arquivo').eq('id', id).maybeSingle();
  if (!data?.storage_path) { toast('Arquivo do currículo não disponível', 'erro'); return null; }
  return data;
}

async function verCurriculo(candidaturaId) {
  const cv = await dadosDoCurriculoDaCandidatura(candidaturaId);
  const url = cv && await urlDoCurriculo(cv.storage_path);
  if (url) window.open(url, '_blank');
}

async function baixarCurriculo(candidaturaId) {
  const cv = await dadosDoCurriculoDaCandidatura(candidaturaId);
  if (!cv) return;
  const { data, error } = await db.storage.from('curriculos').download(cv.storage_path);
  if (error) { toast('Erro ao baixar: ' + error.message, 'erro'); return; }
  const url = URL.createObjectURL(data);
  const a = document.createElement('a');
  a.href = url;
  a.download = cv.nome_arquivo || 'curriculo.pdf';
  a.click();
  URL.revokeObjectURL(url);
}
