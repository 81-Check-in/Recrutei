// ═══════════════════════════════════════════════════════════
//  DASHBOARD
// ═══════════════════════════════════════════════════════════

async function carregarDashboard() {
  const { data, error } = await db.from('vw_dashboard_metricas').select('*').single();
  if (error) { toast('Erro ao carregar métricas', 'erro'); return; }

  const p = app.periodo;
  $('#m-selecionados').textContent = (p === 7 ? data.selecionados_7d : data.selecionados_mes).toLocaleString('pt-BR');
  $('#m-entrevistas').textContent  = (p === 7 ? data.entrevistas_7d  : data.entrevistas_mes).toLocaleString('pt-BR');
  $('#m-excecoes').textContent = data.excecoes_pendentes;
  $('#m-revisao').textContent  = data.revisao_manual_pendente;
  $('#m-sanitizacao').textContent = data.sanitizacao_pendentes;
  atualizarBadgeSanitizacao(data.sanitizacao_pendentes);
  $('#m-curriculos').textContent = data.banco_total.toLocaleString('pt-BR');
  $('#periodo-label').textContent = p === 7 ? 'Últimos 7 dias' : 'Mês atual';

  await Promise.all([carregarFunil(data.banco_total), carregarVagasResumo(), carregarExcecoesResumo()]);
}

// Do banco à contratação: todo o histórico, não o recorte do período (o funil não acompanha o seletor
// "7 dias / Mês atual"). A base é o total do Banco de Talentos; as demais etapas contam candidaturas
// atribuídas pelo RH (vínculos automáticos da triagem antiga não entram).
async function carregarFunil(bancoTotal) {
  const { data, error } = await db
    .from('candidaturas')
    .select('status')
    .eq('status_registro', 'ativo')
    .neq('origem', 'triagem_legada');

  const el = $('#funil');
  if (error) { erro(el, mensagemErro(error)); return; }
  if (!bancoTotal) { vazio(el, 'ti-chart-bar', 'Nenhum candidato no banco'); return; }

  const conta = s => data.filter(d => s.includes(d.status)).length;
  const etapas = [
    { l: 'No banco',      v: bancoTotal, c: '#3B82F6' },
    { l: 'Atribuídos',    v: data.length, c: '#2563EB' },
    { l: 'Entrevistados', v: conta(['entrevista_realizada','aprovado','reprovado','contratado']), c: 'var(--funil-3)' },
    { l: 'Aprovados',     v: conta(['aprovado','contratado']), c: '#16A34A' },
    { l: 'Contratados',   v: conta(['contratado']), c: '#D97706' }
  ];

  el.innerHTML = etapas.map(e => {
    const pct = Math.min(100, Math.round(e.v / bancoTotal * 100));
    return `
    <div class="funil-row">
      <div class="funil-label">${e.l}</div>
      <div class="funil-bg">
        <div class="funil-fill" style="width:${pct}%;background:${e.c}">${pct}%</div>
      </div>
      <div class="funil-num">${e.v}</div>
    </div>`;
  }).join('');
}

async function carregarVagasResumo() {
  // Sem .limit(4) aqui: precisamos de todas as vagas abertas para contar por setor
  // (o card "Setores com vagas abertas" e a legenda de cada mini-card usam essa conta).
  const { data, error } = await db.from('vw_vagas_resumo')
    .select('*').order('total_candidatos', { ascending: false });

  const el = $('#vagas-resumo');
  if (error) { erro(el, error.message); $('#m-vagas').textContent = '—'; return; }

  const porSetor = new Map();
  data.forEach(v => porSetor.set(v.setor_nome, (porSetor.get(v.setor_nome) || 0) + 1));
  $('#m-vagas').textContent = porSetor.size;

  if (!data.length) {
    vazio(el, 'ti-briefcase', 'Nenhuma vaga aberta',
      'Cadastre uma vaga para atribuir candidatos do Banco de Talentos');
    return;
  }

  el.innerHTML = data.slice(0, 4).map(v => {
    const noSetor = porSetor.get(v.setor_nome);
    const meta = noSetor > 1
      ? `${escapeHtml(v.setor_nome)} · ${noSetor} vagas abertas`
      : escapeHtml(v.setor_nome);
    return `
    <div class="vaga-mini" onclick="irPara('vagas')">
      <div class="vaga-mini-icon" style="background:${v.setor_cor}1a;color:${v.setor_cor}">
        <i class="ti ${v.setor_icone}"></i>
      </div>
      <div class="vaga-mini-info">
        <div class="vaga-mini-titulo">${escapeHtml(v.titulo)}</div>
        <div class="vaga-mini-meta">${meta}</div>
      </div>
      <div style="text-align:right">
        <div class="vaga-mini-num">${v.total_candidatos}</div>
        <div class="vaga-mini-lbl">candidatos</div>
      </div>
    </div>`;
  }).join('');
}

async function carregarExcecoesResumo() {
  const { data, error } = await db.from('excecoes')
    .select('email_remetente,tipo,recebido_em')
    .eq('status', 'pendente')
    .order('recebido_em', { ascending: false }).limit(3);

  const el = $('#excecoes-resumo');
  if (error) { erro(el, error.message); return; }
  if (!data.length) {
    vazio(el, 'ti-circle-check', 'Nenhuma exceção pendente');
    return;
  }

  const ICONES = {
    sem_anexo:'ti-mail-off', formato_invalido:'ti-file-x',
    arquivo_corrompido:'ti-file-x', ocr_falhou:'ti-scan',
    docs_privado:'ti-lock', nao_e_curriculo:'ti-file-off',
    vaga_nao_identificada:'ti-help-circle', erro_processamento:'ti-alert-triangle'
  };
  const LABELS = {
    sem_anexo:'Sem currículo', formato_invalido:'Formato inválido',
    arquivo_corrompido:'Sem leitura', ocr_falhou:'OCR falhou',
    docs_privado:'Docs privado', nao_e_curriculo:'Não é currículo',
    vaga_nao_identificada:'Vaga indefinida', erro_processamento:'Erro'
  };

  el.innerHTML = data.map(e => `
    <div class="exc-row">
      <i class="ti ${ICONES[e.tipo]||'ti-alert-triangle'}" style="color:var(--yellow);font-size:17px"></i>
      <div style="flex:1;min-width:0">
        <div class="exc-email">${escapeHtml(e.email_remetente)}</div>
        <div class="exc-meta">${tempoRelativo(e.recebido_em)} · ${LABELS[e.tipo]||e.tipo}</div>
      </div>
      <span class="pill pill-yellow">${LABELS[e.tipo]||e.tipo}</span>
    </div>`).join('');
}

function setPeriodo(p) {
  app.periodo = p;
  $('#btn7').classList.toggle('active', p === 7);
  $('#btn30').classList.toggle('active', p === 30);
  carregarDashboard();
}

