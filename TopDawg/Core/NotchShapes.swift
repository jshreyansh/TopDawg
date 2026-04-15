import SwiftUI

/// Notch body shape with rounded bottom corners
struct NotchLiquidShape: Shape {
    var earRadius: CGFloat = 10
    var bottomCornerRadius: CGFloat = 14

    func path(in rect: CGRect) -> Path {
        var path = Path()

        let w = rect.width
        let h = rect.height
        let er = earRadius
        let bcr = bottomCornerRadius

        path.move(to: CGPoint(x: 0, y: er))

        path.addArc(
            center: CGPoint(x: 0, y: 0),
            radius: er,
            startAngle: Angle(degrees: 90),
            endAngle: Angle(degrees: 0),
            clockwise: false
        )

        path.addLine(to: CGPoint(x: w - er, y: 0))

        path.addArc(
            center: CGPoint(x: w, y: 0),
            radius: er,
            startAngle: Angle(degrees: 180),
            endAngle: Angle(degrees: 90),
            clockwise: false
        )

        path.addLine(to: CGPoint(x: w, y: h - bcr))

        path.addArc(
            center: CGPoint(x: w - bcr, y: h - bcr),
            radius: bcr,
            startAngle: Angle(degrees: 0),
            endAngle: Angle(degrees: 90),
            clockwise: false
        )

        path.addLine(to: CGPoint(x: bcr, y: h))

        path.addArc(
            center: CGPoint(x: bcr, y: h - bcr),
            radius: bcr,
            startAngle: Angle(degrees: 90),
            endAngle: Angle(degrees: 180),
            clockwise: false
        )

        path.addLine(to: CGPoint(x: 0, y: er))
        path.closeSubpath()
        return path
    }
}

/// Ear shape at the corners of the notch
struct NotchEarShape: Shape {
    var isLeftSide: Bool = true

    func path(in rect: CGRect) -> Path {
        var path = Path()
        let w = rect.width
        let h = rect.height

        if isLeftSide {
            path.move(to: CGPoint(x: w, y: 0))
            path.addLine(to: CGPoint(x: w, y: h))
            path.addArc(
                center: CGPoint(x: 0, y: h),
                radius: w,
                startAngle: Angle(degrees: 0),
                endAngle: Angle(degrees: -90),
                clockwise: true
            )
            path.closeSubpath()
        } else {
            path.move(to: CGPoint(x: 0, y: 0))
            path.addLine(to: CGPoint(x: 0, y: h))
            path.addArc(
                center: CGPoint(x: w, y: h),
                radius: w,
                startAngle: Angle(degrees: 180),
                endAngle: Angle(degrees: 270),
                clockwise: false
            )
            path.closeSubpath()
        }

        return path
    }
}
