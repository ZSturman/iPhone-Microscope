import CoreMedia

/// Preserve the exact rational times advertised by capture formats. Decimal
/// conversion can truncate 1/60 enough to request an unsupported 60.000004 FPS.
public enum CaptureTiming {
    public static func duration(minimum: CMTime, maximum: CMTime, limit: CMTime = CMTime(value: 1, timescale: 60)) -> CMTime? {
        guard minimum.isNumeric, maximum.isNumeric, limit.isNumeric,
              minimum > .zero, maximum >= minimum, limit > .zero else { return nil }
        let duration = minimum >= limit ? minimum : limit
        return duration <= maximum ? duration : nil
    }
}
