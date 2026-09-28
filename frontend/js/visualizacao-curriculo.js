// ═══════════════════════════════════════════════════════════
//  VISUALIZAÇÃO DO CURRÍCULO
//  PDF e imagem: o navegador já mostra nativamente — abre a URL assinada numa aba nova, como sempre. Word (.doc/.docx)
//  o navegador não sabe mostrar, só baixar: para o RH não ter que baixar toda vez, .docx é desenhado aqui mesmo no
//  painel (biblioteca docx-preview, carregada só quando precisa, do mesmo CDN já liberado no CSP do painel). O que
//  não dá para desenhar (.doc antigo, .docx que falhar, ou qualquer outro formato) cai no texto que a extração já
//  leu do arquivo — pior que a formatação original, mas sempre alguma coisa, sem obrigar o download.
//  Chamado por banco-talentos.js (cadastro do candidato) e candidatos.js/entrevistas.js (candidatura e agenda).
// ═══════════════════════════════════════════════════════════
const TIPO_DOCX = 'application/vnd.openxmlformats-officedocument.wordprocessingml.document';
const ehImagemMime = tipo => (tipo || '').startsWith('image/');
const ROTULOS_FORMATO = { 'application/msword': 'Word 97-2003 (.doc)', 'text/plain': 'texto simples' };
const rotuloFormatoCurriculo = tipo => ROTULOS_FORMATO[tipo] || (tipo ? tipo.split('/').pop() : 'desconhecido');

// jszip.min.js e docx-preview.js (nesta ordem: a segunda depende da primeira). Uma promessa só: cliques repetidos ou
// vindos de telas diferentes não disparam o carregamento de novo. Falha (ex.: sem internet) deixa tentar de novo depois.
let _carregandoVisualizadorDocx = null;
function carregarVisualizadorDocx() {
  if (window.docx?.renderAsync) return Promise.resolve();
  if (_carregandoVisualizadorDocx) return _carregandoVisualizadorDocx;
  const injetarScript = src => new Promise((resolve, reject) => {
    const el = document.createElement('script');
    el.src = src;
    el.onload = () => resolve();
    el.onerror = () => reject(new Error('Falha ao carregar ' + src));
    document.head.appendChild(el);
  });
  _carregandoVisualizadorDocx = injetarScript('https://cdn.jsdelivr.net/npm/jszip@3.10.1/dist/jszip.min.js')
    .then(() => injetarScript('https://cdn.jsdelivr.net/npm/docx-preview@0.3.6/dist/docx-preview.js'))
    .catch(e => { _carregandoVisualizadorDocx = null; throw e; });
  return _carregandoVisualizadorDocx;
}

// cv: { storage_path, nome_arquivo, tipo_mime, texto_extraido }
async function abrirPreviewCurriculo(cv) {
  if (!cv?.storage_path) { toast('Arquivo do currículo não disponível', 'erro'); return; }

  // PDF e imagem: o próprio navegador mostra melhor que qualquer coisa que a gente desenhasse aqui (zoom, busca, impressão)
  if (cv.tipo_mime === 'application/pdf' || ehImagemMime(cv.tipo_mime)) {
    const url = await urlDoCurriculo(cv.storage_path);
    if (url) window.open(url, '_blank');
    return;
  }

  $('#pv-titulo').textContent = cv.nome_arquivo || 'Currículo';
  $('#pv-corpo').innerHTML = '<div class="estado-vazio"><i class="ti ti-loader-2 girando"></i><p>Carregando...</p></div>';
  $('#pv-baixar').onclick = () => baixarArquivoCurriculo(cv);
  abrirModal('modal-ver-curriculo');

  if (cv.tipo_mime === TIPO_DOCX) {
    try {
      await carregarVisualizadorDocx();
      const { data, error } = await db.storage.from('curriculos').download(cv.storage_path);
      if (error) throw error;
      $('#pv-corpo').innerHTML = '<div id="pv-docx" class="pv-docx"></div>';
      await window.docx.renderAsync(data, $('#pv-docx'), null,
        { className: 'pv-docx-conteudo', inWrapper: false, ignoreWidth: true, ignoreHeight: true, breakPages: false });
      return;
    } catch {
      // arquivo incomum ou biblioteca fora do ar: cai no texto extraído, abaixo
    }
  }
  mostrarTextoExtraidoCurriculo(cv);
}

function mostrarTextoExtraidoCurriculo(cv) {
  const texto = (cv.texto_extraido || '').trim();
  $('#pv-corpo').innerHTML = texto
    ? `<p class="pv-aviso"><i class="ti ti-info-circle"></i>Este formato (${escapeHtml(rotuloFormatoCurriculo(cv.tipo_mime))}) não tem
         visualização com a formatação original aqui no painel. Texto lido do arquivo:</p>
       <pre class="pv-texto">${escapeHtml(texto)}</pre>`
    : `<div class="estado-vazio"><i class="ti ti-file-off"></i><p>Sem visualização disponível para este arquivo</p>
         <span>Baixe para abrir no computador</span></div>`;
}

async function baixarArquivoCurriculo(cv) {
  const { data, error } = await db.storage.from('curriculos').download(cv.storage_path);
  if (error) { toast('Erro ao baixar: ' + mensagemErro(error), 'erro'); return; }
  const url = URL.createObjectURL(data);
  const a = document.createElement('a');
  a.href = url;
  a.download = cv.nome_arquivo || 'curriculo';
  a.click();
  URL.revokeObjectURL(url);
}
