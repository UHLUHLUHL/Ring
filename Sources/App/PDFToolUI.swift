import AppKit
import PDFKit

@MainActor enum PDFToolUI {
    static func present(_ tool:String,model:RingModel) {
        let alert = NSAlert()
        alert.messageText = tool == "metadata" ? "PDF 메타데이터" : (tool == "redact" ? "PDF 콘텐츠 가리기":"PDF 텍스트 주석")
        if tool == "redact" { alert.informativeText="선택 영역의 콘텐츠를 제거한 새 파일을 만듭니다. 경계의 문자는 글자 전체가 제거되도록 영역을 확장합니다. 복잡한 구조나 보존 검증에 실패한 문서는 저장하지 않습니다." }
        alert.addButton(withTitle:"새 파일 저장"); alert.addButton(withTitle:"취소")
        let view = NSStackView(); view.orientation = .vertical;view.alignment = .leading;view.spacing = 8
        var fields: [NSTextField] = []
        let labels = tool == "metadata" ? ["제목","작성자","주제"]:["페이지 (1부터)","왼쪽 X (pt)","아래쪽 Y (pt)","너비 (pt)","높이 (pt)","주석 내용"]
        let fieldLabels = tool == "redact" ? Array(labels.prefix(5)):labels
        let attrs = PDFDocument(url:model.file.url)?.documentAttributes
        let values = tool == "metadata" ? [attrs?[PDFDocumentAttribute.titleAttribute] as? String ?? "",attrs?[PDFDocumentAttribute.authorAttribute] as? String ?? "",attrs?[PDFDocumentAttribute.subjectAttribute] as? String ?? ""]:["1","20","20","220","60",""]
        for (index,label) in fieldLabels.enumerated() {
            view.addArrangedSubview(NSTextField(labelWithString:label))
            let field = NSTextField(string:values[index]); field.widthAnchor.constraint(equalToConstant:300).isActive = true
            fields.append(field); view.addArrangedSubview(field)
        }
        view.frame.size = view.fittingSize
        alert.accessoryView = view
        if alert.runModal() == .alertFirstButtonReturn {
            if tool == "metadata" {
                model.run(.pdfMetadata(PDFMetadata(title:fields[0].stringValue,author:fields[1].stringValue,subject:fields[2].stringValue)))
            } else if tool == "redact" {
                model.run(.pdfRedact(PDFRedaction(page:fields[0].integerValue-1,rect:CGRect(x:fields[1].doubleValue,y:fields[2].doubleValue,width:fields[3].doubleValue,height:fields[4].doubleValue))))
            } else {
                model.run(.pdfNote(PDFNote(page:fields[0].integerValue-1,rect:CGRect(x:fields[1].doubleValue,y:fields[2].doubleValue,width:fields[3].doubleValue,height:fields[4].doubleValue),text:fields[5].stringValue)))
            }
        }
    }
}
