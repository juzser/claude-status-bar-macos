import Foundation

/// Vietnamese phrase catalog, structurally parallel to `MessageStyles.swift`:
/// same ids, same order. Phrases are original, not translations — see
/// the design doc's Style catalog section for the authored set.
enum MessageStylesVi {
    static let all: [MessageStyle] = [
        classic, rpg, gardening, dumb, scifi, cooking, pirate, harrypotter,
    ]

    /// Total lookup: unknown id falls back to Vietnamese classic, not the
    /// English one, so language stays consistent.
    static func style(id: String) -> MessageStyle {
        all.first { $0.id == id } ?? classic
    }

    static let classic = MessageStyle(
        id: "classic", name: "Classic",
        thinking: [
            "Nghiền ngẫm", "Ủ mưu", "Vò đầu", "Nung nấu", "Nhâm nhi ý", "Gỡ rối", "Cân đo",
            "Phác thảo", "Mơ mộng", "Mày mò", "Ngâm ý", "Trăn trở", "Ấp ủ", "Lẩm bẩm",
            "Chắt lọc", "Cân nhắc", "Ấp trứng", "Sáng tác", "Vặn óc", "Nặn óc", "Đun sôi ý",
            "Dò dẫm", "Lắp ráp ý", "Tính toán", "Nhen nhóm", "Ngẫm nghĩ", "Xào nấu ý",
            "Ướp ý tưởng",
        ],
        tool: [
            "Editing": "Đang sửa", "Running": "Đang chạy", "Reading": "Đang đọc",
            "Searching": "Đang tìm", "Browsing": "Đang lướt", "Delegating": "Đang giao việc",
            "Working": "Đang làm",
        ],
        waiting: "Đang chờ bạn")

    static let rpg = MessageStyle(
        id: "rpg", name: "RPG",
        thinking: [
            "Múa kiếm chơi", "Cày cấp độ", "Săn boss trùm", "Bắn chưởng nạp lực", "Mở rương báu",
            "Hú gọi đồng bọn", "Đào mỏ EXP", "Lao vào hầm ngục", "Né đòn chí mạng",
            "Buff máu cả team", "Vái trời khấn Phật", "Combo chưa ra chiêu",
        ],
        tool: [
            "Editing": "Rèn kiếm mới", "Running": "Phang chiêu cái đùng",
            "Reading": "Ngâm cứu sách phép", "Searching": "Lục lọi hang động",
            "Browsing": "Dạo quanh bản đồ", "Delegating": "Sai vặt đồng bọn",
            "Working": "Cày như trâu",
        ],
        waiting: "Đang chờ lệnh sếp")

    static let gardening = MessageStyle(
        id: "gardening", name: "Gardening",
        thinking: [
            "Nhổ cỏ đầu óc", "Ngửi hoa hồng", "Bắt sâu trong đầu", "Tưới cây ý tưởng",
            "Ươm mầm non", "Bón phân cho não", "Ngắm lá vàng rơi", "Cắt tỉa hoa héo",
            "Tỉa cành lung tung", "Đào đất trồng cây", "Ngắt hoa hái quả",
            "Hái cà chua chín",
        ],
        tool: [
            "Editing": "Tỉa cành lẹ tay", "Running": "Xới đất ầm ầm",
            "Reading": "Đọc túi hạt giống", "Searching": "Săn lùng cỏ dại",
            "Browsing": "Dạo một vòng vườn", "Delegating": "Sai yêu tinh vườn",
            "Working": "Cắm mặt làm vườn",
        ],
        waiting: "Rau chín rồi đó")

    static let dumb = MessageStyle(
        id: "dumb", name: "Dumb",
        thinking: [
            "Não đang load", "Đơ 5 giây", "Não đang toang nhẹ", "Chưa nghĩ ra gì",
            "Khum biết nghĩ gì", "Nạp thêm IQ", "Não cá vàng", "Bấm nút restart não",
            "Có ai không đó", "Xin dừng suy nghĩ", "Đứng hình chấm cơm", "Flex cái đầu rỗng",
        ],
        tool: [
            "Editing": "Gõ chữ loạn xạ", "Running": "Chạy đại cho rồi", "Reading": "Đọc mà không hiểu",
            "Searching": "Tìm hoài chưa thấy", "Browsing": "Lướt web vô định",
            "Delegating": "Nhờ đứa khác làm", "Working": "Làm được tí gì",
        ],
        waiting: "Tới lượt bạn đó")

    static let scifi = MessageStyle(
        id: "scifi", name: "Sci-Fi",
        thinking: [
            "Dò sóng lạ", "Sạc pin photon", "Tính giờ warp", "Du hành xuyên không",
            "Giải mã tín hiệu", "Canh giờ đổ bộ", "Khám phá hành tinh", "Ngắm sao băng bay",
            "Vá lỗ đen", "Dò UFO ngoài kia", "Nạp nhiên liệu warp", "Ghé trạm vũ trụ",
        ],
        tool: [
            "Editing": "Vá lại con chip", "Running": "Nổ máy tăng tốc",
            "Reading": "Dò dữ liệu cũ", "Searching": "Quét khắp ngân hà",
            "Browsing": "Dò kênh liên lạc", "Delegating": "Điều robot đi làm",
            "Working": "Chạy full công suất",
        ],
        waiting: "Chờ lệnh chỉ huy")

    static let cooking = MessageStyle(
        id: "cooking", name: "Cooking",
        thinking: [
            "Pha cà phê muối", "Nướng bánh đồng xu", "Lắc trân châu", "Làm bánh tráng trộn",
            "Thử thách mì cay", "Trà chanh giã tay", "Múc chè khúc bạch", "Làm gỏi cuốn tôm",
            "Lẩu tự sôi", "Cơm cháy kho quẹt", "Sữa chua nếp cẩm", "Nhúng bánh mì que",
        ],
        tool: [
            "Editing": "Bày biện đẹp mắt", "Running": "Đảo chảo xèo xèo",
            "Reading": "Xem clip nấu ăn", "Searching": "Lùng nguyên liệu hiếm",
            "Browsing": "Lướt TikTok ẩm thực", "Delegating": "Nhắn ship đồ ăn",
            "Working": "Nấu cơm cả tuần",
        ],
        waiting: "Bụng đang réo rồi")

    static let pirate = MessageStyle(
        id: "pirate", name: "Pirate",
        thinking: [
            "Ngắm la bàn Jack", "Triệu hồi quái Kraken", "Mặc cả Davy Jones", "Nhấp rượu rum",
            "Vàng Aztec bị nguyền", "Kéo cờ đen", "Chờ tàu Ngọc Trai", "Nhớ luật hải tặc",
            "Lướt ngang đảo vàng", "Né tàu ma bay", "Xin được parley", "Dong buồm ra khơi",
        ],
        tool: [
            "Editing": "Trét nhựa vỏ tàu", "Running": "Khai hỏa đại bác",
            "Reading": "Đọc nhật ký Jones", "Searching": "Săn vàng bị nguyền",
            "Browsing": "Ngó qua ống nhòm", "Delegating": "Hô hào cả đoàn",
            "Working": "Cọ sàn dưới trăng",
        ],
        waiting: "La bàn chỉ bạn")

    static let harrypotter = MessageStyle(
        id: "harrypotter", name: "Harry Potter",
        thinking: [
            "Niệm Wingardium Leviosa", "Niệm Expecto Patronum", "Khẽ hô Alohomora",
            "Dựng khiên Protego", "Đọc tâm trí Legilimens", "Xua boggart bằng Riddikulus",
            "Hóa giải Finite Incantatem", "Trói chặt Petrificus Totalus",
            "Cách âm bằng Muffliato", "Chọc cười Rictusempra", "Niệm nhanh Stupefy",
            "Gọi chim Avis",
        ],
        tool: [
            "Editing": "Sửa đồ bằng Reparo", "Running": "Niệm Avada Kedavra",
            "Reading": "Soi chữ bằng Revelio", "Searching": "Triệu hồi bằng Accio",
            "Browsing": "Dò hướng Point Me", "Delegating": "Sai cú đưa thư",
            "Working": "Dọn dẹp bằng Scourgify",
        ],
        waiting: "Chờ lệnh phù thủy")
}
