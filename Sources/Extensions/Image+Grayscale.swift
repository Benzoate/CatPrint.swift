import UIKit
import Accelerate

extension CGImage {
    
    func addWhiteBackground() -> CGImage {
        guard [.none, .noneSkipLast, .noneSkipFirst].contains(self.alphaInfo) == false else { return self }
        
        let size = CGSize(width: width, height: height)
        UIGraphicsBeginImageContextWithOptions(size, false, 1)
                
        guard let ctx = UIGraphicsGetCurrentContext() else { return self }
        defer { UIGraphicsEndImageContext() }
        
        let rect = CGRect(origin: .zero, size: size)
        ctx.setFillColor(UIColor.white.cgColor)
        ctx.fill(rect)
        ctx.concatenate(CGAffineTransform(a: 1, b: 0, c: 0, d: -1, tx: 0, ty: size.height))
        ctx.draw(self, in: rect)
        
        return UIGraphicsGetImageFromCurrentImageContext()?.cgImage ?? self
    }

    func toGrayscale() -> CGImage {
        // Our job here is done
        guard colorSpace?.numberOfComponents != 1 else { return self }

        guard let format = vImage_CGImageFormat(cgImage: self),
              // The source image bufffer
              var sourceBuffer = try? vImage_Buffer(
                cgImage: self,
                format: format
              ),
              // The 1-channel, 8-bit vImage buffer used as the operation destination.
              var destinationBuffer = try? vImage_Buffer(
                width: Int(sourceBuffer.width),
                height: Int(sourceBuffer.height),
                bitsPerPixel: 8
              ) else {
            return self
        }

        // Declare the three coefficients that model the eye's sensitivity
        // to color.
        let redCoefficient: Float = 0.2126
        let greenCoefficient: Float = 0.7152
        let blueCoefficient: Float = 0.0722

        // Create a 1D matrix containing the three luma coefficients that
        // specify the color-to-grayscale conversion.
        let divisor: Int32 = 0x1000
        let fDivisor = Float(divisor)

        var coefficientsMatrix = [
            Int16(redCoefficient * fDivisor),
            Int16(greenCoefficient * fDivisor),
            Int16(blueCoefficient * fDivisor)
        ]

        // Use the matrix of coefficients to compute the scalar luminance by
        // returning the dot product of each RGB pixel and the coefficients
        // matrix.
        let preBias: [Int16] = [0, 0, 0, 0]
        let postBias: Int32 = 0

        vImageMatrixMultiply_ARGB8888ToPlanar8(
            &sourceBuffer,
            &destinationBuffer,
            &coefficientsMatrix,
            divisor,
            preBias,
            postBias,
            vImage_Flags(kvImageNoFlags)
        )

        // Create a 1-channel, 8-bit grayscale format that's used to
        // generate a displayable image.
        guard let monoFormat = vImage_CGImageFormat(
            bitsPerComponent: 8,
            bitsPerPixel: 8,
            colorSpace: CGColorSpaceCreateDeviceGray(),
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue),
            renderingIntent: .defaultIntent
        ) else {
                return self
        }

        // Create a Core Graphics image from the grayscale destination buffer.
        guard let result = try? destinationBuffer.createCGImage(format: monoFormat) else {
            return self
        }

        return result
    }
}
