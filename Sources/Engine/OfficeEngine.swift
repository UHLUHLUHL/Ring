import Foundation
import AppKit
import WebKit
import PDFKit

enum OfficeEngine {
    static func render(_ source:URL,to output:URL,format:ImageFormat,options:DocumentRenderOptions = .init()) async throws -> String {
        guard [.pdf,.png,.jpg,.webp].contains(format),
              [options.pageSize.width,options.pageSize.height,options.margin,options.dpi].allSatisfy(\.isFinite),
              (100...2000).contains(options.pageSize.width),(100...2000).contains(options.pageSize.height),
              options.margin>=0,options.margin*2<min(options.pageSize.width,options.pageSize.height),
              (72...600).contains(options.dpi) else { throw EngineError.invalid("문서 용지·여백·해상도 오류") }
        let html=try DocumentSource.html(source)
        let renderer=await DocumentRenderer(options:options)
        let pages=try await renderer.pdf(html:html,to:output,asPDF:format == .pdf)
        if format != .pdf {
            // WKWebView creates vector pages first; rasterization uses a bounded page buffer.
            let pdfURL=output.deletingLastPathComponent().appendingPathComponent("document-render.pdf")
            defer { try? FileManager.default.removeItem(at:pdfURL) }
            let document=try PDFEngine.open(pdfURL)
            try FileManager.default.createDirectory(at:output,withIntermediateDirectories:false)
            for i in 0..<document.pageCount {
                try Task.checkCancellation()
                try autoreleasepool {
                    let image=try PDFEngine.renderWithAnnotations(document.page(at:i)!,scale:options.dpi/72)
                    let file=output.appendingPathComponent(String(format:"%04d.%@",i+1,format.rawValue))
                    if format == .webp {
                        let bytes=try TargetSizeCodec.memoryEncode(ExternalCodecs.straightRGBA8(image),width:image.width,height:image.height,icc:image.colorSpace?.copyICCData() as Data? ?? Data(),webp:true,quality:95)
                        try bytes.write(to:file)
                        let written=try ImageInput(file)
                        guard written.image.width==image.width,written.image.height==image.height else { throw EngineError.quality("문서 이미지 크기 검증 실패") }
                    } else {
                        try ImageCodec.write(image,properties:[:],format:format,to:file)
                        try ImageCodec.verify(image,properties:[:],output:file,exact:format == .png)
                    }
                }
                EngineProgress.step(i,of:document.pageCount)
            }
        }
        return "\(pages)페이지 · 네트워크 차단 WebKit · \(format == .pdf ? "벡터 PDF":"\(Int(options.dpi))dpi 이미지")"
    }
}

@MainActor private final class DocumentRenderer: NSObject,WKNavigationDelegate {
    private let web:WKWebView,options:DocumentRenderOptions
    private var loading:CheckedContinuation<Void,Error>?
    init(options:DocumentRenderOptions) {
        self.options=options
        let config=WKWebViewConfiguration()
        config.websiteDataStore = .nonPersistent()
        config.defaultWebpagePreferences.allowsContentJavaScript=false
        config.preferences.javaScriptCanOpenWindowsAutomatically=false
        web=WKWebView(frame:CGRect(origin:.zero,size:options.pageSize),configuration:config)
        super.init();web.navigationDelegate=self
    }
    func pdf(html:String,to output:URL,asPDF:Bool) async throws -> Int {
        defer { web.stopLoading();web.navigationDelegate=nil }
        let rules="""
        [{"trigger":{"url-filter":".*"},"action":{"type":"block"}}]
        """
        let list=try await WKContentRuleListStore.default().compileContentRuleList(forIdentifier:"RingOfflineDocuments-v2",encodedContentRuleList:rules)
        if let list { web.configuration.userContentController.add(list) }
        let width=options.pageSize.width,height=options.pageSize.height,margin=options.margin
        let template="""
        <!doctype html><html><head><meta charset="utf-8"><meta http-equiv="Content-Security-Policy" content="default-src 'none'; img-src data:; style-src 'unsafe-inline'; font-src data:; connect-src 'none'; frame-src 'none'; script-src 'none'; object-src 'none'; base-uri 'none'; form-action 'none'"><style>
        *{box-sizing:border-box}html,body{margin:0;padding:0;background:white;color:#181818;font:11pt -apple-system,Arial,sans-serif;line-height:1.45}#pages{width:\(width)px}.ring-page{width:\(width)px;height:\(height)px;padding:\(margin)px;overflow:hidden;background:white}.ring-content{width:100%;height:100%;overflow:hidden}p{margin:0 0 8pt}h1,h2,h3,h4,h5,h6{line-height:1.2;break-after:avoid}table{border-collapse:collapse;width:100%;table-layout:fixed}td,th{border:0.5pt solid #bbb;padding:4pt;vertical-align:top;overflow-wrap:anywhere}img{max-width:100%;object-fit:contain}pre{white-space:pre-wrap;overflow-wrap:anywhere}p,li{overflow-wrap:anywhere}#source{position:absolute;visibility:hidden;left:-10000px;width:\(width-2*margin)px}
        </style></head><body><div id="source"></div><div id="pages"></div></body></html>
        """
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                loading=continuation;web.loadHTMLString(template,baseURL:nil)
                Task { [weak self] in
                    try? await Task.sleep(nanoseconds:20_000_000_000)
                    self?.finish(EngineError.io("문서 WebKit 로드 시간 초과"))
                }
            }
        } onCancel: { Task { @MainActor [weak self] in self?.finish(CancellationError()) } }
        try Task.checkCancellation()
        let result: Any = try await withCheckedThrowingContinuation { continuation in
            web.callAsyncJavaScript(Self.paginate,arguments:["raw":html],in:nil,in:.defaultClient) { continuation.resume(with:$0) }
        }
        guard let count=result as? Int,count>0,count<=1000 else { throw EngineError.quality("문서 페이지 나누기 실패") }
        let target=asPDF ? output : output.deletingLastPathComponent().appendingPathComponent("document-render.pdf")
        var media=CGRect(origin:.zero,size:options.pageSize)
        guard let combined=CGContext(target as CFURL,mediaBox:&media,nil) else { throw EngineError.io("문서 PDF 생성 실패") }
        for i in 0..<count {
            try Task.checkCancellation()
            let configuration=WKPDFConfiguration()
            configuration.rect=CGRect(x:0,y:Double(i)*height,width:width,height:height)
            let bytes=try await web.pdf(configuration:configuration)
            guard let provider=CGDataProvider(data:bytes as CFData),let pdf=CGPDFDocument(provider),let page=pdf.page(at:1) else { throw EngineError.quality("WebKit 벡터 페이지 검증 실패") }
            combined.beginPDFPage(nil)
            combined.drawPDFPage(page);combined.endPDFPage()
            EngineProgress.step(i,of:count)
        }
        combined.closePDF()
        let written=try PDFEngine.open(target)
        guard written.pageCount==count else { throw EngineError.quality("문서 PDF 페이지 수 불일치") }
        return count
    }
    private func finish(_ error:Error? = nil) {
        guard let continuation=loading else { return };loading=nil
        if let error { continuation.resume(throwing:error) } else { continuation.resume() }
    }
    func webView(_ webView:WKWebView,didFinish navigation:WKNavigation!) { finish() }
    func webView(_ webView:WKWebView,didFail navigation:WKNavigation!,withError error:Error) { finish(error) }
    func webView(_ webView:WKWebView,didFailProvisionalNavigation navigation:WKNavigation!,withError error:Error) { finish(error) }
    func webViewWebContentProcessDidTerminate(_ webView:WKWebView) { finish(EngineError.io("문서 WebKit 프로세스 종료")) }
    func webView(_ webView:WKWebView,decidePolicyFor action:WKNavigationAction,decisionHandler:@escaping(WKNavigationActionPolicy)->Void) {
        decisionHandler(action.request.url?.absoluteString == "about:blank" && loading != nil ? .allow:.cancel)
    }
    private static let paginate = #"""
    const parsed=new DOMParser().parseFromString(raw,'text/html');
    if(parsed.querySelectorAll('*').length>100000)throw Error('Document node budget exceeded');
    const sheets=[...parsed.querySelectorAll('style')].map(s=>s.textContent).join('\n');
    for(const e of parsed.querySelectorAll('script,iframe,frame,object,embed,base,link,meta,form,style,svg,math')) e.remove();
    for(const e of parsed.querySelectorAll('*')) {
      for(const a of [...e.attributes]) if(/^on/i.test(a.name)||['href','srcset','action'].includes(a.name)) e.removeAttribute(a.name);
      if(e.hasAttribute('src')&&!/^data:image\/(png|jpeg|gif|webp);base64,/i.test(e.getAttribute('src'))) e.removeAttribute('src');
      if(e.hasAttribute('style')) {
        const s=e.style;for(const key of [...s]) if(!['font-size','font-weight','font-style','font-family','text-align','text-decoration','color','background-color','width','height','max-width','line-height','white-space'].includes(key)) s.removeProperty(key);
      }
    }
    const source=document.getElementById('source'),shadow=source.attachShadow({mode:'open'});
    const style=document.createElement('style');style.textContent=sheets;shadow.append(style);
    const contentRoot=document.createElement('div');shadow.append(contentRoot);contentRoot.append(...parsed.body.childNodes);
    // Ignore promises from user content; only inline images can load under the CSP.
    await Promise.all([...contentRoot.querySelectorAll('img')].map(im=>im.decode().catch(()=>{})));
    await document.fonts.ready;
    const allowed=['font-size','font-weight','font-style','font-family','text-align','text-decoration','color','background-color','line-height','white-space'];
    for(const e of contentRoot.querySelectorAll('*')){const cs=getComputedStyle(e);if(cs.display==='none'){e.remove();continue;}for(const key of allowed)e.style.setProperty(key,cs.getPropertyValue(key));e.removeAttribute('class');e.removeAttribute('id');}
    const root=document.getElementById('pages');let content=null,pages=0;
    function page(){if(++pages>1000)throw Error('Page budget exceeded');const p=document.createElement('section');p.className='ring-page';content=document.createElement('div');content.className='ring-content';p.append(content);root.append(p);return content;}
    page();const capacity=()=>content.clientHeight;
    const fits=()=>content.scrollHeight<=capacity()+0.5;
    function fragment(node,start,end){const r=document.createRange(),w=document.createTreeWalker(node,NodeFilter.SHOW_TEXT);let text,pos=0,a=null,b=null;
      while(text=w.nextNode()){const n=text.length;if(a===null&&start<=pos+n)a=[text,Math.max(0,start-pos)];if(end<=pos+n){b=[text,end-pos];break;}pos+=n;}
      const clone=node.cloneNode(false);if(a&&b){r.setStart(...a);r.setEnd(...b);clone.append(r.cloneContents());}return clone;}
    function paragraph(node){const text=node.textContent;if(!text.length||node.querySelector('img,table'))throw Error('Unsplittable document element');
      const ends=[...new Intl.Segmenter('ko',{granularity:'word'}).segment(text)].map(s=>s.index+s.segment.length);let start=0;
      while(start<text.length){let lo=0,hi=ends.length-1,best=-1,trial=null;
        while(lo<=hi){const mid=(lo+hi)>>1,end=ends[mid];if(end<=start){lo=mid+1;continue;}const test=fragment(node,start,end);content.append(test);const ok=fits();test.remove();if(ok){best=mid;lo=mid+1;}else hi=mid-1;}
        if(best<0){if(content.childNodes.length){page();continue;}throw Error('Word or glyph exceeds page bounds');}
        content.append(fragment(node,start,ends[best]));start=ends[best];if(start<text.length)page();
      }
    }
    function table(node){const rows=[...node.querySelectorAll(':scope > tbody > tr,:scope > tr')],head=node.querySelector('thead');let t=null,body=null;
      function fresh(){t=node.cloneNode(false);if(head)t.append(head.cloneNode(true));body=document.createElement('tbody');t.append(body);content.append(t);}
      fresh();for(const row of rows){body.append(row.cloneNode(true));if(fits())continue;body.lastChild.remove();if(!body.childNodes.length)t.remove();page();fresh();body.append(row.cloneNode(true));if(!fits())throw Error('Table row exceeds page height');}
    }
    function add(node){if(node.nodeType===Node.TEXT_NODE){if(!node.textContent.trim())return;const p=document.createElement('p');p.textContent=node.textContent;node=p;}
      if(node.nodeType!==Node.ELEMENT_NODE)return;
      if(node.tagName==='IMG'){node.style.maxHeight=capacity()+'px';node.style.maxWidth='100%';node.style.width='auto';node.style.height='auto';}
      content.append(node);if(fits())return;node.remove();
      if(node.tagName==='TABLE'){table(node);return;}
      if(['DIV','SECTION','ARTICLE','MAIN','UL','OL','BLOCKQUOTE'].includes(node.tagName)){for(const child of [...node.childNodes])add(child);return;}
      if(content.childNodes.length)page();content.append(node);if(fits())return;node.remove();paragraph(node);
    }
    for(const node of [...contentRoot.childNodes])add(node);source.remove();
    if(!content.childNodes.length&&pages>1){content.parentElement.remove();pages--;}
    return pages;
    """#
}
