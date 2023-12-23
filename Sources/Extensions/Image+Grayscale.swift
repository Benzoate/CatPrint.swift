import Accelerate

extension CGImage {
    
    func addWhiteBackground() -> CGImage {
        // No alpha anyway
        guard [.none, .noneSkipLast, .noneSkipFirst].contains(self.alphaInfo) == false else { return self }
        
        guard var format = vImage_CGImageFormat(cgImage: self),
              let topBuffer = try? vImage.PixelBuffer<vImage.Interleaved8x4>(cgImage: self, cgImageFormat: &format) else {
            return self
        }
        let bottomLayer = vImage.PixelBuffer<vImage.Interleaved8x4>(size: topBuffer.size)
        let destinationBuffer = vImage.PixelBuffer<vImage.Interleaved8x4>(size: topBuffer.size)

        _ = bottomLayer.withUnsafePointerToVImageBuffer { pointer in
            vImageBufferFill_ARGB8888(pointer, [255, 255, 255, 255], 0)
        }

        if [.last, .premultipliedLast, .noneSkipLast].contains(alphaInfo) {
            topBuffer.permuteChannels(
                to: (3, 0, 1, 2),
                destination: topBuffer
            )
        }
        
        bottomLayer.alphaComposite(
            .premultiplied,
            topLayer: topBuffer,
            destination: destinationBuffer
        )
        
        
        guard let destinationFormat = vImage_CGImageFormat(
            bitsPerComponent: 8,
            bitsPerPixel: 32,
            colorSpace: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipFirst.rawValue)
        ) else {
            return self
        }
        
        return destinationBuffer.makeCGImage(
            cgImageFormat: destinationFormat
        ) ?? self
    }

    func toGrayscale() -> CGImage {
        // Our job here is done
        guard colorSpace?.numberOfComponents != 1 else { return self }

        guard var format = vImage_CGImageFormat(cgImage: self),
              let sourceBuffer = try? vImage.PixelBuffer<vImage.Interleaved8x4>(
                cgImage: self,
                cgImageFormat: &format
              )
        else {
            
            return self
        }
        // Move alpha channel if necessary
        if [.last, .premultipliedLast, .noneSkipLast].contains(alphaInfo) {
            sourceBuffer.permuteChannels(
                to: (3, 0, 1, 2),
                destination: sourceBuffer
            )
        }

        let destinationBuffer = vImage.PixelBuffer<vImage.Planar8>(width: width, height: height)

        // Declare the three coefficients that model the eye's sensitivity
        // to color.
        let redCoefficient: Float = 0.2126
        let greenCoefficient: Float = 0.7152
        let blueCoefficient: Float = 0.0722

        // Create a 1D matrix containing the three luma coefficients that
        // specify the color-to-grayscale conversion.
        let divisor: Int = 0x1000
        let fDivisor = Float(divisor)

        let coefficientsMatrix: (Int, Int, Int, Int) = (
            0,
            Int(redCoefficient * fDivisor),
            Int(greenCoefficient * fDivisor),
            Int(blueCoefficient * fDivisor)
        )

        // Use the matrix of coefficients to compute the scalar luminance by
        // returning the dot product of each RGB pixel and the coefficients
        // matrix.
        let preBias: (Int, Int, Int, Int) = (0, 0, 0, 0)
        let postBias: Int = 0
        sourceBuffer.multiply(
            by: coefficientsMatrix,
            divisor: divisor,
            preBias: preBias,
            postBias: postBias,
            destination: destinationBuffer
        )
        
        guard let destinationFormat = vImage_CGImageFormat(
            bitsPerComponent: 8,
            bitsPerPixel: 8,
            colorSpace: CGColorSpaceCreateDeviceGray(),
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue)
        ) else { return self }
        
        return destinationBuffer.makeCGImage(cgImageFormat: destinationFormat) ?? self
    }
}
