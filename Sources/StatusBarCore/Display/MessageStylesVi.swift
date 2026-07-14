import Foundation

/// Vietnamese phrase catalog, structurally parallel to `MessageStyles.swift`:
/// same 7 ids, same order. Phrases are original, not translations — see
/// the design doc's Style catalog section for the authored set.
enum MessageStylesVi {
    static let all: [MessageStyle] = [
        classic, rpg, gardening, dumb, scifi, cooking, pirate,
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
            "Múa kiếm chơi", "Cày cấp độ", "Săn boss trùm", "Đọc thần chú", "Mở rương báu",
            "Hú gọi đồng bọn", "Đào mỏ EXP", "Ngáo phép thuật", "Né đòn chí mạng",
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
            "Ươm mầm non", "Bón phân cho não", "Ngắm lá vàng rơi", "Hóng nắng thư giãn",
            "Tỉa cành lung tung", "Đào đất trồng cây", "Ngắt hoa hái quả",
            "Trốn nắng trong vườn",
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
            "Não đang load", "Đơ 5 giây", "Ủa cái gì", "Chưa nghĩ ra gì", "Đầu óc trên mây",
            "Nạp thêm IQ", "Não cá vàng", "Bấm nút restart não", "Có ai không đó",
            "Lú thiệt sự", "Đứng hình chấm cơm", "Suy nghĩ hộ cái",
        ],
        tool: [
            "Editing": "Gõ chữ loạn xạ", "Running": "Bấm nút to đùng", "Reading": "Ngó lơ ngơ",
            "Searching": "Tìm hoài chưa thấy", "Browsing": "Lướt web vô định",
            "Delegating": "Nhờ đứa khác làm", "Working": "Làm được tí gì",
        ],
        waiting: "Tới lượt bạn đó")

    static let scifi = MessageStyle(
        id: "scifi", name: "Sci-Fi",
        thinking: [
            "Dò sóng lạ", "Sạc pin photon", "Tính giờ warp", "Du hành xuyên không",
            "Giải mã tín hiệu", "Canh giờ đổ bộ", "Buôn chuyện với AI", "Ngắm sao băng bay",
            "Vá lỗ đen", "Dò UFO ngoài kia", "Nạp nhiên liệu warp", "Chỉnh ăng-ten dò sóng",
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
            "Nêm cho vừa", "Lật bánh lẹ", "Múa dao đầu bếp", "Canh lửa liu riu",
            "Nếm thử chút xíu", "Ướp cho ngấm vị", "Đảo đều tay nào", "Hầm cho mềm nhừ",
            "Trộn đều gia vị", "Canh nồi sôi trào", "Bào vỏ thái lát", "Nướng cho vàng đều",
        ],
        tool: [
            "Editing": "Bày món lên đĩa", "Running": "Bật bếp lửa to",
            "Reading": "Đọc công thức nấu", "Searching": "Sục sạo tủ lạnh",
            "Browsing": "Dạo chợ mua đồ", "Delegating": "Gọi phụ bếp ra",
            "Working": "Đứng bếp cả ngày",
        ],
        waiting: "Lên món rồi đó")

    static let pirate = MessageStyle(
        id: "pirate", name: "Pirate",
        thinking: [
            "Dò kho báu", "Buộc dây neo", "Nghe lỏm tin đồn", "Ngắm sao định hướng",
            "Mài lưỡi đao cong", "Đếm vàng trong rương", "Nhìn xa trông biển",
            "Nói chuyện với vẹt", "Cột chặt nút dây", "Vượt qua bão to", "Dò tìm đảo giấu",
            "Lau ống nhòm sáng",
        ],
        tool: [
            "Editing": "Vá lại cánh buồm", "Running": "Khai hỏa đại bác",
            "Reading": "Nghiên cứu bản đồ", "Searching": "Đào bới tìm vàng",
            "Browsing": "Dò xét chân trời", "Delegating": "Hô hào cả đoàn",
            "Working": "Cọ sàn tàu",
        ],
        waiting: "Chờ lệnh thuyền trưởng")
}
