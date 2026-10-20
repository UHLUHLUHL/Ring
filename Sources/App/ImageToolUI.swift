import AppKit

@MainActor enum ImageToolUI {
    static func annotation(model:RingModel) {
        let alert = NSAlert();alert.messageText = "이미지 주석"
        alert.informativeText = "내용을 입력한 뒤 이미지에서 주석을 넣을 영역을 선택합니다."
        let field = NSTextField(frame:NSRect(x:0,y:0,width:300,height:48))
        field.placeholderString = "주석 내용";alert.accessoryView = field
        alert.addButton(withTitle:"위치 선택");alert.addButton(withTitle:"취소")
        if alert.runModal() == .alertFirstButtonReturn,!field.stringValue.isEmpty {
            model.regionPurpose = .annotate(field.stringValue);model.screen = .crop
        }
    }
    static func adjust(model:RingModel) {
        let alert = NSAlert();alert.messageText = "이미지 보정"
        alert.informativeText = "기본값은 노출 0, 대비 1, 채도 1입니다. 결과는 PNG로 저장합니다."
        let view = NSStackView();view.orientation = .vertical;view.alignment = .leading;view.spacing = 8
        var fields: [NSTextField] = []
        for (name,value) in [("노출 EV (-5…5)","0"),("대비 (0…3)","1"),("채도 (0…3)","1")] {
            view.addArrangedSubview(NSTextField(labelWithString:name))
            let field = NSTextField(string:value);field.widthAnchor.constraint(equalToConstant:280).isActive = true
            fields.append(field);view.addArrangedSubview(field)
        }
        view.frame.size = view.fittingSize;alert.accessoryView = view
        alert.addButton(withTitle:"새 파일 저장");alert.addButton(withTitle:"취소")
        if alert.runModal() == .alertFirstButtonReturn {
            model.run(.edit(.adjust(exposure:fields[0].doubleValue,contrast:fields[1].doubleValue,saturation:fields[2].doubleValue)))
        }
    }
}
