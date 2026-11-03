import Foundation

/// Strings of the Health app itself — category, sleep stage, and detail
/// labels — from the iOS Health frameworks' own tables (HealthUI,
/// HealthExperienceUI, HealthRecordsUI), which exist only on iOS. Read from
/// the device by RenduTests/HealthUIStringsDump (iOS 27.2); nothing here is
/// translated by hand.
enum HealthUIStrings {
    static var chinese: Bool { Bundle.main.preferredLocalizations.first?.hasPrefix("zh") == true }

    static func localized(_ key: String) -> String? {
        (chinese ? zhHans : en)[key]
    }

    /// "%@" formats ("REM Intervals: %@").
    static func format(_ key: String, _ argument: String) -> String? {
        localized(key)?.replacingOccurrences(of: "%@", with: argument)
    }

    /// INTERVALS_OF_TIME_NUMBERED_UNIT: "1 interval", "4 intervals", "4个时间间隔".
    static func intervals(_ count: Int) -> String {
        chinese ? "\(count)个时间间隔" : count == 1 ? "1 interval" : "\(count.formatted()) intervals"
    }

    static let en: [String: String] = [
        "FITNESS": "Activity",
        "BODY_MEASUREMENTS": "Body Measurements",
        "REPRODUCTIVE_HEALTH": "Cycle Tracking",
        "HEARING_HEALTH": "Hearing",
        "HEART": "Heart",
        "MEDICATION_TRACKING": "Medications",
        "MENTAL_WELLBEING": "Mental Wellbeing",
        "MOBILITY": "Mobility",
        "NUTRITION": "Nutrition",
        "RESPIRATORY": "Respiratory",
        "SLEEP": "Sleep",
        "SYMPTOMS": "Symptoms",
        "VITAL_SIGNS": "Vitals",
        "OTHER": "Other Data",
        "browse_categories_header_title": "Health Categories",
        "IN_BED": "In Bed",
        "AWAKE": "Awake",
        "ASLEEP_REM": "REM",
        "ASLEEP_CORE": "Core",
        "ASLEEP_DEEP": "Deep",
        "ASLEEP_UNSPECIFIED": "Asleep",
        "IN_BED_INTERVALS": "In Bed Intervals: %@",
        "AWAKE_INTERVALS": "Awake Intervals: %@",
        "ASLEEP_REM_INTERVALS": "REM Intervals: %@",
        "ASLEEP_CORE_INTERVALS": "Core Intervals: %@",
        "ASLEEP_DEEP_INTERVALS": "Deep Intervals: %@",
        "ASLEEP_UNSPECIFIED_INTERVALS": "Asleep Intervals: %@",
        "ALL_DATA_TITLE": "All Recorded Data",
        "DETAILS": "Details",
        "SAMPLE_DETAILS": "Sample Details",
        "DEVICE_DETAILS": "Device Details",
        "CLINICAL_ACCOUNTS_SOURCE_DETAILS": "Source Details",
        "DATE": "Date",
        "START_TIME": "Start Time",
        "END_TIME": "End Time",
        "SOURCE": "Source",
        "HKTimeZone": "Time Zone",
        "BROWSE_TITLE": "Browse",
        "SEARCH_PLACEHOLDER": "Search",
    ]

    static let zhHans: [String: String] = [
        "FITNESS": "健身记录",
        "BODY_MEASUREMENTS": "身体测量",
        "REPRODUCTIVE_HEALTH": "经期追踪",
        "HEARING_HEALTH": "听觉",
        "HEART": "心脏",
        "MEDICATION_TRACKING": "用药",
        "MENTAL_WELLBEING": "心理健康",
        "MOBILITY": "活动能力",
        "NUTRITION": "营养摄入",
        "RESPIRATORY": "呼吸",
        "SLEEP": "睡眠",
        "SYMPTOMS": "症状",
        "VITAL_SIGNS": "生命体征",
        "OTHER": "其他数据",
        "browse_categories_header_title": "健康类别",
        "IN_BED": "卧床时间",
        "AWAKE": "清醒时间",
        "ASLEEP_REM": "快速动眼睡眠",
        "ASLEEP_CORE": "核心睡眠",
        "ASLEEP_DEEP": "深度睡眠",
        "ASLEEP_UNSPECIFIED": "睡眠",
        "IN_BED_INTERVALS": "卧床时间间隔：%@",
        "AWAKE_INTERVALS": "清醒时间间隔：%@",
        "ASLEEP_REM_INTERVALS": "快速动眼睡眠时间间隔：%@",
        "ASLEEP_CORE_INTERVALS": "核心睡眠时间间隔：%@",
        "ASLEEP_DEEP_INTERVALS": "深度睡眠时间间隔：%@",
        "ASLEEP_UNSPECIFIED_INTERVALS": "睡眠时间间隔：%@",
        "ALL_DATA_TITLE": "所有已记录的数据",
        "DETAILS": "详细信息",
        "SAMPLE_DETAILS": "样本详细信息",
        "DEVICE_DETAILS": "设备详细信息",
        "CLINICAL_ACCOUNTS_SOURCE_DETAILS": "来源详细信息",
        "DATE": "日期",
        "START_TIME": "开始时间",
        "END_TIME": "结束时间",
        "SOURCE": "来源",
        "HKTimeZone": "时区",
        "BROWSE_TITLE": "浏览",
        "SEARCH_PLACEHOLDER": "搜索",
    ]
}
