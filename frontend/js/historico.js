// ═══════════════════════════════════════════════════════════
//  HISTÓRICO DO CANDIDATO
//  Substitui a planilha Excel do processo seletivo: quem veio e quem não veio, uma linha por entrevista. Aprovado, Reprovado e Não
//  compareceu entram SOZINHOS quando o resultado é registrado na tela Entrevistas (gatilho do banco, backend/sql/042); Sem interesse e
//  Desistência (depois de aprovado: documentação, treinamento) o RH registra aqui. Nome, celular, data, setor da vaga e status são copiados
//  para a própria tabela e continuam aqui mesmo depois de os dados do candidato serem excluídos do Banco de Talentos; só o administrador
//  apaga uma linha. O painel só LÊ a tabela: as gravações passam por historico_registrar / historico_alterar / historico_excluir.
// ═══════════════════════════════════════════════════════════

const HISTORICO_STATUS = {
  aprovado:       { rotulo: 'Aprovado',       classe: 'pill-green' },
  reprovado:      { rotulo: 'Reprovado',      classe: 'pill-red' },
  sem_interesse:  { rotulo: 'Sem interesse',  classe: 'pill-gray' },
  nao_compareceu: { rotulo: 'Não compareceu', classe: 'pill-purple' },
  desistencia:    { rotulo: 'Desistência',    classe: 'pill-yellow' }
};
const HISTORICO_ORIGEM = { sistema: 'Automático (tela Entrevistas)', manual: 'Registrado à mão', planilha: 'Importado da planilha' };
const HISTORICO_DICA_STATUS = {
  aprovado: 'Veio à entrevista e foi aprovado. Quando o resultado é registrado em Entrevistas, este status entra sozinho.',
  reprovado: 'Veio à entrevista e não foi aprovado.',
  sem_interesse: 'A pessoa não tem interesse na vaga (antes ou sem entrevista).',
  nao_compareceu: 'Estava agendada e não veio.',
  desistencia: 'Foi aprovado e desistiu depois (por exemplo na documentação ou no treinamento). Conte na observação em que etapa foi.'
};
const HISTORICO_ESCOLARIDADE = { nenhuma: 'Sem escolaridade', fundamental: 'Fundamental', medio: 'Médio', tecnico: 'Técnico', superior: 'Superior', pos: 'Pós-graduação' };
const HISTORICO_POR_PAGINA = 50;

const estadoHistorico = { versao: 0, carregados: 0, total: 0, linhas: new Map() };
let historicoEditando = null;            // id da linha aberta no modal (null = novo registro)
let temporizadorHistorico = null;

function erroHistorico(error) {
  if (error?.code === 'PGRST202' || error?.code === 'PGRST205' || /schema cache/.test(error?.message || ''))
    return 'O Histórico do candidato ainda não foi habilitado no banco de dados. Rode backend/sql/042_historico_candidato.sql.';
  return mensagemErro(error);
}

// "2026-09-25" -> "25/09/2026" sem passar por Date (que trocaria o dia por causa do fuso)
const dataDoHistorico = iso => iso ? iso.split('-').reverse().join('/') : '—';

function buscarHistorico() {                // espera a pessoa parar de digitar
  clearTimeout(temporizadorHistorico);
  temporizadorHistorico = setTimeout(() => carregarHistorico(), 250);
}

async function carregarHistorico(mais = false) {
  const corpo = $('#hist-body');
  const versao = ++estadoHistorico.versao;
  if (!mais) { estadoHistorico.carregados = 0; estadoHistorico.linhas.clear(); }

  const nome = normBusca($('#hist-nome').value.trim());
  const digitos = $('#hist-tel').value.replace(/\D/g, '');
  const status = $('#hist-status').value;

  let q = db.from('vw_historico_candidatos').select('*', { count: 'exact' })
    .order('data_evento', { ascending: false }).order('criado_em', { ascending: false })
    .range(estadoHistorico.carregados, estadoHistorico.carregados + HISTORICO_POR_PAGINA - 1);
  if (nome)    q = q.like('nome_norm', `%${escaparLike(nome)}%`);              // parcial; índice trigrama
  if (digitos) q = q.like('telefone_digitos', `%${digitos}%`);                 // só números: "(61) 99999-1234" acha "61999991234"
  if (status)  q = q.eq('status', status);

  const { data, error, count } = await q;
  if (versao !== estadoHistorico.versao) return;                               // outra busca começou enquanto esta esperava

  if (error) {
    corpo.innerHTML = `<tr><td colspan="7"><div class="estado-vazio erro"><i class="ti ti-alert-triangle"></i><p>${escapeHtml(erroHistorico(error))}</p></div></td></tr>`;
    $('#hist-contador').textContent = 'Não foi possível carregar o histórico';
    $('#hist-mais').style.display = 'none';
    return;
  }
  data.forEach(h => estadoHistorico.linhas.set(h.id, h));
  estadoHistorico.carregados += data.length;
  estadoHistorico.total = count ?? estadoHistorico.carregados;

  const filtrando = !!(nome || digitos || status);
  $('#hist-contador').textContent = estadoHistorico.total === 0
    ? (filtrando ? 'Nenhum registro com esses filtros' : 'Nenhum registro ainda')
    : `${estadoHistorico.total} registro${estadoHistorico.total > 1 ? 's' : ''}${filtrando ? ' com esses filtros' : ''}`;

  if (!estadoHistorico.carregados) {
    corpo.innerHTML = `<tr><td colspan="7"><div class="estado-vazio"><i class="ti ti-history"></i>
      <p>${filtrando ? 'Nada encontrado' : 'O histórico está vazio'}</p>
      <span>${filtrando ? 'Tente outro trecho do nome ou do telefone' : 'Os resultados registrados em Entrevistas aparecem aqui sozinhos. Para sem interesse ou desistência, use “Novo registro”.'}</span></div></td></tr>`;
  } else {
    const html = data.map(htmlLinhaHistorico).join('');
    if (mais) corpo.insertAdjacentHTML('beforeend', html); else corpo.innerHTML = html;
  }
  $('#hist-mais').style.display = estadoHistorico.carregados < estadoHistorico.total ? '' : 'none';
}

function maisHistorico() { carregarHistorico(true); }

function htmlLinhaHistorico(h) {
  const st = HISTORICO_STATUS[h.status] || { rotulo: h.status, classe: 'pill-gray' };
  return `<tr class="hist-linha" data-id="${h.id}">
    <td>${dataDoHistorico(h.data_evento)}</td>
    <td class="hist-nome" onclick="alternarDetalheHistorico('${h.id}')" title="Ver detalhes">${escapeHtml(h.nome)}</td>
    <td>${h.telefone ? escapeHtml(h.telefone) : '<span class="sem-dados">—</span>'}</td>
    <td>${h.setor_vaga ? escapeHtml(h.setor_vaga) : '<span class="sem-dados">—</span>'}</td>
    <td><span class="pill ${st.classe}">${st.rotulo}</span></td>
    <td class="hist-obs" title="${escapeHtml(h.observacao || '')}">${h.observacao ? escapeHtml(h.observacao) : '<span class="sem-dados">—</span>'}</td>
    <td class="hist-acoes">
      <button type="button" class="btn-sm" onclick="alternarDetalheHistorico('${h.id}')" title="Ver detalhes"><i class="ti ti-chevron-down"></i></button>
      <button type="button" class="btn-sm" onclick="abrirRegistroHistorico('${h.id}')" title="Corrigir status, observação ou dados"><i class="ti ti-pencil"></i>Alterar</button>
      ${ehAdministrador() ? `<button type="button" class="btn-sm vermelho" onclick="excluirRegistroHistorico('${h.id}')" title="Exclui a linha (só o administrador)"><i class="ti ti-trash"></i></button>` : ''}
    </td>
  </tr>`;
}

// ── Detalhes: o que ainda existe do cadastro do candidato ──
function alternarDetalheHistorico(id) {
  const linha = document.querySelector(`#hist-body tr.hist-linha[data-id="${id}"]`);
  if (!linha) return;
  const aberto = linha.nextElementSibling?.classList.contains('hist-detalhe');
  if (aberto) { linha.nextElementSibling.remove(); return; }
  const h = estadoHistorico.linhas.get(id);
  if (!h) return;
  const dado = (rotulo, valor) => `<div class="dado"><div class="dado-lbl">${rotulo}</div><div class="dado-val">${escapeHtml(valor || '—')}</div></div>`;
  const local = [h.cidade ? `${h.cidade}${h.uf ? '/' + h.uf : ''}` : '', h.regiao_nome].filter(Boolean).join(' · ');
  const classificacao = [h.area_sugerida, h.cargo_sugerido, rotuloNivel(h.nivel_sugerido)].filter(Boolean).join(' / ');
  // O currículo e a análise da IA continuam acessíveis daqui enquanto o cadastro existir (ativo, em processo ou inativo); depois que os dados
  // são excluídos, o histórico guarda só o essencial e os botões dão lugar ao aviso
  const cadastro = h.candidato_situacao
    ? `<button type="button" class="btn-sm" onclick="verCurriculoDoCandidato('${h.candidato_id}')"><i class="ti ti-file-text"></i>Ver currículo</button>
       <button type="button" class="btn-sm" onclick="abrirTalento('${h.candidato_id}')"><i class="ti ti-sparkles"></i>Ver cadastro e análise da IA</button>`
    : '<span class="sem-dados">Os dados deste candidato (currículo e análise da IA) não estão mais no Banco de Talentos: o histórico guarda só o essencial.</span>';
  linha.insertAdjacentHTML('afterend', `<tr class="hist-detalhe"><td colspan="7">
    <div class="hist-grade">
      ${dado('Vaga', h.vaga_titulo)}
      ${dado('E-mail', h.email)}
      ${dado('Mora em', local)}
      ${dado('Setor / função / nível do currículo', classificacao)}
      ${dado('Escolaridade', HISTORICO_ESCOLARIDADE[h.escolaridade])}
      ${dado('Experiência', h.anos_experiencia != null ? `${h.anos_experiencia} ano${Number(h.anos_experiencia) === 1 ? '' : 's'}` : '')}
      ${dado('Entrevistador', h.entrevistador)}
      ${dado('Origem do registro', HISTORICO_ORIGEM[h.origem] || h.origem)}
      ${dado('Registrado por', h.registrado_por_nome)}
      ${dado('Última alteração', h.atualizado_em ? fmtDataHora(h.atualizado_em) : '')}
      ${h.observacao ? `<div class="hist-obs-completa"><strong>Observação:</strong> ${escapeHtml(h.observacao)}</div>` : ''}
      <div style="grid-column:1/-1">${cadastro}</div>
    </div></td></tr>`);
}

// ── Novo registro / alterar ──
function dicaStatusHistorico() {
  $('#hist-f-dica').textContent = HISTORICO_DICA_STATUS[$('#hist-f-status').value] || '';
}

function abrirRegistroHistorico(id) {
  const h = id ? estadoHistorico.linhas.get(id) : null;
  historicoEditando = h ? h.id : null;
  $('#hist-f-titulo').textContent = h ? 'Alterar registro do histórico' : 'Novo registro no histórico';

  // setor: os da empresa; um valor antigo que não está na lista (registro importado, setor renomeado) não some em silêncio
  const nomes = (app.cache.setores || []).map(s => s.nome);
  if (h?.setor_vaga && !nomes.includes(h.setor_vaga)) nomes.push(h.setor_vaga);
  $('#hist-f-setor').innerHTML = '<option value="">Não informado</option>' +
    nomes.map(n => `<option value="${escapeHtml(n)}">${escapeHtml(n)}</option>`).join('');

  $('#hist-f-nome').value = h?.nome || '';
  $('#hist-f-tel').value = h?.telefone || '';
  $('#hist-f-data').value = h?.data_evento || new Date().toLocaleDateString('sv-SE');      // sv-SE = AAAA-MM-DD, no fuso do navegador
  $('#hist-f-setor').value = h?.setor_vaga || '';
  $('#hist-f-vaga').value = h?.vaga_titulo || '';
  $('#hist-f-status').value = h?.status || '';
  $('#hist-f-obs').value = h?.observacao || '';
  dicaStatusHistorico();

  const aviso = $('#hist-f-aviso');
  aviso.style.display = h && h.origem === 'sistema' && !h.alterado_manual ? '' : 'none';
  aviso.textContent = 'Esta linha veio da tela Entrevistas. Ao alterá-la aqui ela deixa de acompanhar a entrevista: o que você corrigir não é mais refeito.';
  abrirModal('modal-historico');
  $('#hist-f-nome').focus();
}

async function salvarRegistroHistorico() {
  const dados = {
    nome: $('#hist-f-nome').value.trim(),
    telefone: $('#hist-f-tel').value.trim(),
    data_evento: $('#hist-f-data').value,
    setor_vaga: $('#hist-f-setor').value,
    vaga_titulo: $('#hist-f-vaga').value.trim(),
    status: $('#hist-f-status').value,
    observacao: $('#hist-f-obs').value.trim()
  };
  if (!dados.nome) { toast('Informe o nome', 'erro'); return; }
  if (!dados.data_evento) { toast('Informe a data', 'erro'); return; }
  if (!dados.status) { toast('Escolha o status', 'erro'); return; }

  const btn = $('#hist-f-salvar');
  btn.disabled = true;
  let error;
  if (historicoEditando) {
    const antes = estadoHistorico.linhas.get(historicoEditando) || {};
    const mudou = {};                                                          // só o que mudou (a auditoria guarda o nome dos campos)
    for (const [campo, valor] of Object.entries(dados)) if (valor !== String(antes[campo] ?? '')) mudou[campo] = valor;
    if (!Object.keys(mudou).length) { btn.disabled = false; fecharModal('modal-historico'); return; }
    ({ error } = await db.rpc('historico_alterar', { p_id: historicoEditando, p_dados: mudou }));
  } else {
    ({ error } = await db.rpc('historico_registrar', { p_dados: dados }));
  }
  btn.disabled = false;
  if (error) { toast(erroHistorico(error), 'erro'); return; }
  fecharModal('modal-historico');
  toast(historicoEditando ? 'Registro atualizado' : 'Registro criado');
  await carregarHistorico();
}

async function excluirRegistroHistorico(id) {
  const h = estadoHistorico.linhas.get(id);
  if (!h || !ehAdministrador()) return;
  if (!await confirmar({
    titulo: 'Excluir registro do histórico?', rotulo: 'Excluir',
    mensagem: `Remove ${h.nome} (${HISTORICO_STATUS[h.status]?.rotulo || h.status}, ${dataDoHistorico(h.data_evento)}) do histórico. Não dá para desfazer; a exclusão fica na auditoria.`
  })) return;
  const { error } = await db.rpc('historico_excluir', { p_id: id });
  if (error) { toast(erroHistorico(error), 'erro'); return; }
  toast('Registro excluído');
  await carregarHistorico();
}
