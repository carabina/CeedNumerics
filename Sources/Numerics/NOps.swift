/*
Copyright (c) 2018-present Creaceed SPRL and other CeedNumerics contributors.

Redistribution and use in source and binary forms, with or without
modification, are permitted provided that the following conditions are met:
    * Redistributions of source code must retain the above copyright
      notice, this list of conditions and the following disclaimer.
    * Redistributions in binary form must reproduce the above copyright
      notice, this list of conditions and the following disclaimer in the
      documentation and/or other materials provided with the distribution.
    * Neither the name of Creaceed SPRL nor the
      names of its contributors may be used to endorse or promote products
      derived from this software without specific prior written permission.

THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS "AS IS" AND
ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE IMPLIED
WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE ARE
DISCLAIMED. IN NO EVENT SHALL CREACEED SPRL BE LIABLE FOR ANY
DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL DAMAGES
(INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES;
LOSS OF USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND
ON ANY THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT
(INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE OF THIS
SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.
*/

import Foundation
import Accelerate

// Padding
public enum PaddingMode {
	case edge
	// case zero
	// case mirror
}

/// Convolution
public enum ConvolutionDomain {
	case same // M
	case valid // M-K+1
	// case full // M+K-1
}

// MARK: - Generic Dimensional Type Ops
// (apply to Vector, Matrix, Tensor)
// Typically element-wise operations that can be implemented in terms to linearized access (any dimensions).
extension Numerics where Element: NAccelerateFloatingPoint {
	public static func subtract<DT: NDimensionalArray>(_ a: DT, _ b: DT, _ result: DT) where DT.Element == Element {
		precondition(a.size == b.size && a.size == result.size)
		
		withLinearizedAccesses(a, b, result) { aacc, bacc, racc in
			Element.mx_vsub(aacc.base, aacc.stride, bacc.base, bacc.stride, racc.base, racc.stride, numericCast(racc.count))
		}
	}
	
	public static func mean<DT: NDimensionalArray>(_ a: DT) -> DT.Element where DT.Element == Element {
		var mean: Element = 0.0
		var c = 0
		withLinearizedAccesses(a) { alin in
			// possibly invoked multiple types
			var lm: Element = 0.0
			Element.mx_meanv(alin.base, alin.stride, C: &lm, numericCast(alin.count))
			mean += lm
			c += 1
		}
		return mean / Element(max(1,c))
	}
	public static func meanSquare<DT: NDimensionalArray>(_ a: DT) -> DT.Element where DT.Element == Element {
		var mean: Element = 0.0
		var c = 0
		withLinearizedAccesses(a) { alin in
			// possibly invoked multiple types
			var lm: Element = 0.0
			Element.mx_measqv(alin.base, alin.stride, C: &lm, numericCast(alin.count))
			mean += lm
			c += 1
		}
		return mean / Element(max(1,c))
	}
	public static func minimum<DT: NDimensionalArray>(_ a: DT) -> DT.Element where DT.Element == Element {
		var m: Element = Element.infinity
		withLinearizedAccesses(a) { alin in
			// possibly invoked multiple types
			var lm: Element = 0.0
			Element.mx_minv(alin.base, alin.stride, C: &lm, numericCast(alin.count))
			m = min(m, lm)
		}
		return m
	}
	public static func maximum<DT: NDimensionalArray>(_ a: DT) -> DT.Element where DT.Element == Element {
		var m: Element = -Element.infinity
		withLinearizedAccesses(a) { alin in
			// possibly invoked multiple types
			var lm: Element = 0.0
			Element.mx_maxv(alin.base, alin.stride, C: &lm, numericCast(alin.count))
			m = max(m, lm)
		}
		return m
	}
	
	public static func subtract<DT: NDimensionalArray>(_ a: DT, _ b: DT) -> DT where DT.Element == Element { return a._deriving { subtract(a, b, $0) } }
}

extension Numerics where Element: NAdditiveNumeric {
	// debugging / testing
	public static func _setIndexRamp<DT: NDimensionalArray>(_ a: DT) where DT.Element == Element {
		var val: Element = .none
		for index in a.indices {
			a[index] = val
			val += .one
		}
	}
}


// MARK: - Vector Ops
extension Numerics where Element: NAccelerateFloatingPoint {
	/// Creation of vectors
	public static func zeros(count: Int) -> Vector { return Vector(repeating: 0.0, size: count) }
	public static func ones(count: Int) -> Vector { return NVector(repeating: 1.0, size: count) }
	
	// note: stop is included
	public static func linspace(start: Element, stop: Element, count: Int, output: Vector) {
		precondition(count == output.size)
		precondition(count >= 2)
		
		withStorageAccess(output) { oaccess in
			Element.mx_vramp(start, (stop-start)/Element(count-1), oaccess.base, numericCast(oaccess.stride), numericCast(oaccess.count))
		}
	}
	
	// note: stop is not included
	public static func range(start: Element = 0.0, stop: Element, step: Element = 1.0) -> Vector {
		precondition((stop - start) * step > 0.0)
		precondition(step != 0.0)
		
		// predictable count
		let count: Int = ceil((stop - start) / step).roundedIntValue
		
		return linspace(start: start, stop: start + Element(count-1)*step, count: count)
	}
	
	public static func linspace(start: Element, stop: Element, count: Int) -> Vector {
		precondition(count >= 2)
		let output = Vector(size: count)
		linspace(start: start, stop: stop, count: count, output: output)
		return output
	}
	
	// Median (brute force)
	public static func median(input: Vector, kernel K: Int) -> Vector {
		precondition(K % 2 == 1 && K > 0)
		let output = Vector(size: input.size)
		guard input.size > 0 else { return output }
		
		let HK = K / 2
		var window = [Element](repeating: Element.none, count: K)// NVector(size: kernel)
		let auginput = Vector(size: 2*HK + input.size)
		let N = input.size
		
		// Prepare augmented input (TODO: could have different conditions here)
		for i in 0..<HK {
			auginput[i] = input[0]
			auginput[HK+N+i] = input[N-1]
		}
		for i in 0..<N {
			auginput[i+HK] = input[i]
		}
		//		print("aug: \(auginput)")
		
		// Main loop
		for i in 0..<N {
			let ai = HK + i
			// fill window
			for j in 0..<K {
				window[j] = auginput[ai-HK+j]
			}
			window.sort()
			output[i] = window[HK]
		}
		
		return output
	}
	
	// .valid domain only (no allocation), because that's what natively supported in Accelerate
	public static func convolve(input: Vector, kernel: Vector, output: Vector) {
		let M = input.size
		let K = kernel.size
		let O = output.size
		
		precondition(K > 0)
		precondition(M >= kernel.size)
		precondition(O == M - K + 1)
		
		withStorageAccess(input, kernel, output) { iaccess, kaccess, oaccess in
			// TODO: check negative stride is supported for input/output (doc only mentions kernel)
			Element.mx_conv(iaccess.base, iaccess.stride, kaccess.base, kaccess.stride, oaccess.base, oaccess.stride, numericCast(oaccess.count), numericCast(kaccess.count))
		}
	}
	
	public static func pad(input: Vector, before: Int, after: Int, mode: PaddingMode = .edge, output: Vector) {
		precondition(before >= 0)
		precondition(after >= 0)
		precondition(input.size > 0) // for edge mode
		
		let afterstart = before+input.size
		
		output[before ..< afterstart] = input
		output[0 ..< before] = NVector(repeating: input.first!, size: before)
		output[afterstart ..< output.size] = NVector(repeating: input.last!, size: after)
	}
	
	// Arithmetic
	public static func scaledAdd(_ a: Vector, _ asp: Element, _ b: Vector, _ bs: Element, _ output: Vector) {
		precondition(a.size == b.size && a.size == output.size)
		
		withStorageAccess(a, b, output) { aacc, bacc, oacc in
			// TODO: check negative stride is supported for input/output (doc only mentions kernel)
			Element.mx_vsmsma(aacc.base, aacc.stride, asp, bacc.base, bacc.stride, bs, oacc.base, oacc.stride, numericCast(aacc.count))
		}
	}
	
	public static func lerp(_ a: Vector, _ b: Vector, _ t: Element, _ result: Vector) {
		return scaledAdd(a, 1.0-t, b, t, result)
	}
	public static func lerp(_ a: Vector, _ b: Vector, _ t: Element) -> Vector { return a._deriving { scaledAdd(a, 1.0-t, b, t, $0) } }
	
	public static func multiply(_ a: Element, _ b: Vector, _ result: Vector) {
		precondition(b.shape == result.shape)
		withStorageAccess(b, result) { bacc, racc in
			Element.mx_vsmul(bacc.base, bacc.stride, a, racc.base, racc.stride, numericCast(racc.count))
		}
	}
	public static func multiply(_ a: Element, _ b: Vector) -> Vector { return b._deriving { multiply(a, b, $0) } }
	// Obvious swaps
	public static func multiply(_ a: Vector, _ b: Element, _ result: Vector) { multiply(b, a, result) }
	public static func multiply(_ a: Vector, _ b: Element) -> Vector { return multiply(b, a) }
	
	public static func multiply(_ a: Vector, _ b: Vector, _ result: Vector) {
		precondition(a.size == b.size && b.size == result.size)
		
		withStorageAccess(a, b, result) { aacc, bacc, racc in
			Element.mx_vmul(aacc.base, aacc.stride, bacc.base, bacc.stride, racc.base, racc.stride, numericCast(racc.count))
		}
	}
	public static func multiply(_ a: Vector, _ b: Vector) -> Vector { return a._deriving { multiply(a, b, $0) } }
	
//	public static func subtract(_ a: Vector, _ b: Vector, _ result: Vector) {
//		precondition(a.shape == b.shape && a.shape == result.shape)
//		withStorageAccess(a, b, result) { aacc, bacc, racc in
//			Element.mx_vsub(aacc.base, aacc.stride, bacc.base, bacc.stride, racc.base, racc.stride, numericCast(racc.count))
//		}
//	}
//	public static func subtract(_ a: Vector, _ b: Vector) -> Vector { return a._deriving { subtract(a, b, $0) } }
	public static func add(_ a: Vector, _ b: Vector, _ result: Vector) {
		precondition(a.shape == b.shape && a.shape == result.shape)
		withStorageAccess(a, b, result) { aacc, bacc, racc in
			Element.mx_vadd(aacc.base, aacc.stride, bacc.base, bacc.stride, racc.base, racc.stride, numericCast(racc.count))
		}
	}
	public static func add(_ a: Vector, _ b: Vector) -> Vector { return a._deriving { add(a, b, $0) } }
	public static func add(_ a: Vector, _ b: Element, _ result: Vector) {
		precondition(a.shape == result.shape)
		withStorageAccess(a, result) { aacc, racc in
			Element.mx_vsadd(aacc.base, aacc.stride, b, racc.base, racc.stride, numericCast(racc.count))
		}
	}
	public static func add(_ a: Vector, _ b: Element) -> Vector { return a._deriving { add(a, b, $0) } }
	
	public static func cumsum(_ a: Vector) -> Vector {
		precondition(a.size > 0)
		let result = a.copy()
		
		// because of vDSP implementation
		if a.size > 1 {
			result[1] = result[0] + result[1]
		}
		
		withStorageAccess(result) { racc in
			// in-place. OK?
			Element.mx_vrsum(racc.base, racc.stride, 1.0, racc.base, racc.stride, numericCast(racc.count))
		}
		result[0] = a[0]
		return result
	}
}

// MARK: - Vector: Deriving new ones + operators
extension NVector where Element: NAccelerateFloatingPoint {
	public var mean: Element { return Numerics.mean(self) }
	public var meanSquare: Element { return Numerics.meanSquare(self) }
	public var maximum: Element { return Numerics.maximum(self) }
	public var minimum: Element { return Numerics.minimum(self) }
	
	public func padding(before: Int, after: Int, mode: PaddingMode = .edge) -> Vector {
		precondition(before >= 0)
		precondition(after >= 0)
		precondition(self.size > 0) // for edge mode
		
		let output = NVector(size: self.size + before + after)
		
		num.pad(input: self, before: before, after: after, mode: mode, output: output)
		
		return output
	}
	public func convolving(kernel: Vector, domain: ConvolutionDomain = .same, padding: PaddingMode = .edge) -> Vector {
		precondition(self.size >= kernel.size)
		
		let M = self.size
		let K = kernel.size
		let output: Vector, vinput: Vector
		
		switch domain {
		case .same:
			let bk = K/2, ek = K-1-bk
			vinput = self.padding(before: bk, after: ek)
			output = NVector(size: M)
		case .valid:
			vinput = self
			output = NVector(size: M - K + 1)
		}
		
		num.convolve(input: vinput, kernel: kernel, output: output)
		return output
	}
	
	// Operators here too. Scoped + types are easier to write.
	public static func +(lhs: Vector, rhs: Element) -> Vector { return Numerics.add(lhs, rhs) }
	public static func -(lhs: Vector, rhs: Element) -> Vector { return Numerics.add(lhs, -rhs) }
	public static func *(lhs: Element, rhs: Vector) -> Vector { return Numerics.multiply(lhs, rhs) }
	public static func *(lhs: Vector, rhs: Element) -> Vector { return Numerics.multiply(lhs, rhs) }
	public static func *(lhs: Vector, rhs: Vector) -> Vector { return Numerics.multiply(lhs, rhs) }
	
	public static func -(lhs: Vector, rhs: Vector) -> Vector { return Numerics.subtract(lhs, rhs) }
	public static func +(lhs: Vector, rhs: Vector) -> Vector { return Numerics.add(lhs, rhs) }
	
	public static func +=(lhs: Vector, rhs: Element) { Numerics.add(lhs, rhs, lhs) }
	public static func -=(lhs: Vector, rhs: Element) { Numerics.add(lhs, -rhs, lhs) }
	public static func +=(lhs: Vector, rhs: Vector) { Numerics.add(lhs, rhs, lhs) }
	public static func *=(lhs: Vector, rhs: Element) { Numerics.multiply(lhs, rhs, lhs) }
	public static func *=(lhs: Vector, rhs: Vector) { Numerics.multiply(lhs, rhs, lhs) }
}


// MARK: - Matrix Ops
extension Numerics where Element: NAccelerateFloatingPoint {
	public static func zeros(rows: Int, columns: Int) -> Matrix { return Matrix(repeating: 0.0, rows: rows, columns: columns) }
	public static func ones(rows: Int, columns: Int) -> Matrix { return Matrix(repeating: 1.0, rows: rows, columns: columns) }
//	public static func add(_ a: Vector, _ b: Vector, _ result: Vector) {
//		precondition(a.shape == b.shape && a.shape == result.shape)
//		withStorageAccess(a, b, result) { aacc, bacc, racc in
//			Element.mx_vadd(aacc.base, aacc.stride, bacc.base, bacc.stride, racc.base, racc.stride, numericCast(racc.count))
//		}
//	}
//	public static func add(_ a: Vector, _ b: Vector) -> Vector { return a._deriving { add(a, b, $0) } }
	
	public static func multiply(_ a: Matrix, _ b: Element, _ result: Matrix) {
		precondition(a.shape == result.shape)
		
		// New implementation, try it!
		withLinearizedAccesses(a, result) { alin, rlin in
			// possibly invoked multiple types
			Element.mx_vsmul(alin.base, 1, b, rlin.base, 1, numericCast(alin.count))
		}
	}
	// swap + deriving
	public static func multiply(_ a: Element, _ b: Matrix, _ result: Matrix) { multiply(b, a, result) }
	public static func multiply(_ a: Matrix, _ b: Element) -> Matrix { return a._deriving { multiply(a, b, $0) } }
	public static func multiply(_ a: Element, _ b: Matrix) -> Matrix { return multiply(b, a) }
	
	public static func multiply(_ a: Matrix, _ b: Matrix, _ result: Matrix) {
		precondition(a.columns == b.rows)
		
		withStorageAccess(a) { aacc in
			withStorageAccess(b) { bacc in
				withStorageAccess(result) { racc in
					if aacc.compact && bacc.compact && racc.compact {
						
						assert(aacc.stride.column == 1); assert(aacc.stride.row == aacc.count.column)
						assert(bacc.stride.column == 1); assert(bacc.stride.row == bacc.count.column)
						assert(racc.stride.column == 1); assert(racc.stride.row == racc.count.column)
						
						Element.mx_gemm(order: CblasRowMajor, transA: CblasNoTrans, transB: CblasNoTrans, M: numericCast(a.rows), N: numericCast(b.columns), K: numericCast(a.columns), alpha: 1.0, A: aacc.base, lda: numericCast(aacc.stride.row), B: bacc.base, ldb: numericCast(bacc.stride.row), beta: 0.0, C: racc.base, ldc: numericCast(racc.stride.row))
					} else {
						fatalError("not implemented")
					}
				}
			}
		}
	}
	public static func multiply(_ a: Matrix, _ b: Matrix) -> Matrix {
		let result = Matrix(rows: a.rows, columns: b.columns)
		multiply(a, b, result)
		return result
	}
	
	public static func multiply(_ a: Matrix, _ b: Vector, _ result: Vector) {
		precondition(a.columns == b.size)
		
		withStorageAccess(a) { aacc in
			withStorageAccess(b, result) { bacc, racc in
				if aacc.compact && bacc.compact && racc.compact {
					assert(aacc.stride.column == 1); assert(aacc.stride.row == aacc.count.column)
					assert(bacc.stride == 1)
					assert(racc.stride == 1)
					
					Element.mx_gemm(order: CblasRowMajor, transA: CblasNoTrans, transB: CblasNoTrans, M: numericCast(a.rows), N: 1, K: numericCast(a.columns), alpha: 1.0, A: aacc.base, lda: numericCast(aacc.stride.row), B: bacc.base, ldb: numericCast(bacc.stride), beta: 0.0, C: racc.base, ldc: numericCast(racc.stride))
				} else {
					fatalError("not implemented")
				}
			}
		}
	}
	public static func multiply(_ a: Matrix, _ b: Vector) -> Vector {
		let result = Vector(size: a.rows)
		multiply(a, b, result)
		return result
	}
	
	// TODO: improve API naming.
	public static func elementWiseMultiply(_ a: Matrix, _ b: Matrix, _ result: Matrix) {
		precondition(a.shape == b.shape && a.shape == result.shape)
		
		withStorageAccess(a, b, result) { aacc, bacc, racc in
			if aacc.compact && bacc.compact && racc.compact {
				Element.mx_vmul(aacc.base, 1, bacc.base, 1, racc.base, 1, numericCast(aacc.count.row * aacc.count.column))
			} else {
				for i in 0..<aacc.count.row {
					Element.mx_vmul(aacc.base(row: i), aacc.stride.column,
									bacc.base(row: i), bacc.stride.column,
									racc.base(row: i), racc.stride.column,
									numericCast(aacc.count.column))
				}
			}
		}
	}
	
	public static func divide(_ a: Matrix, _ b: Matrix, _ result: Matrix) {
		precondition(a.shape == b.shape && a.shape == result.shape)
		
		withStorageAccess(a) { aacc in
			withStorageAccess(b) { bacc in
				withStorageAccess(result) { racc in
					if aacc.compact && bacc.compact && racc.compact {
						Element.mx_vdiv(aacc.base, 1, bacc.base, 1, racc.base, 1, numericCast(a.rows * a.columns))
						//						print("\(aacc.base)")
					} else {
						fatalError("not implemented")
					}
				}
			}
		}
	}
	public static func divide(_ a: Matrix, _ b: Matrix) -> Matrix { return a._deriving { divide(a, b, $0) } }
	
	
	public static func transpose(_ src: Matrix, _ output: Matrix) {
		assert(output.rows == src.columns)
		assert(output.columns == src.rows)
		
		withStorageAccess(src) { sacc in
			withStorageAccess(output) { oacc in
				if sacc.compact && oacc.compact {
					assert(sacc.stride.column == 1 && sacc.stride.row == sacc.count.column)
					assert(oacc.stride.column == 1 && oacc.stride.row == oacc.count.column)
					
					// rows columns of result (inverted).
					Element.mx_mtrans(sacc.base, 1, oacc.base, 1, numericCast(src.columns), numericCast(src.rows))
				} else {
					let sslice = sacc.slice, oslice = oacc.slice
					for i in 0..<sslice.row.rcount {
						for j in 0..<sslice.column.rcount {
							oacc.base[oslice.position(j,i)] = sacc.base[sslice.position(i,j)]
						}
					}
				}
			}
		}
	}
}

extension Numerics where Element == Float {
	// because of vImage, don't have double impl.
	public static func convolve(input: Matrix, kernel: Matrix, output: Matrix) {
		precondition(kernel.rows % 2 == 1 && kernel.columns % 2 == 1)
		precondition(kernel.compact)
		
		withStorageAccess(input, kernel, output) { iacc, kacc, oacc in
			if kacc.compact && iacc.stride.column == 1 && oacc.stride.column == 1 {
				var ivim = iacc.vImage
				var ovim = oacc.vImage

				vImageConvolve_PlanarF(&ivim, &ovim, nil, 0, 0, kacc.base, numericCast(kacc.count.row), numericCast(kacc.count.column), 0.0, vImage_Flags(kvImageBackgroundColorFill))
			} else {
				fatalError("not implemented")
			}
			
		}
	}
}


// MARK: - Matrix: Deriving new ones + operators
extension NMatrix where Element: NAccelerateFloatingPoint {
	public var mean: Element { return Numerics.mean(self) }
	public var meanSquare: Element { return Numerics.meanSquare(self) }
	public var maximum: Element { return Numerics.maximum(self) }
	public var minimum: Element { return Numerics.minimum(self) }
	
	
	public func transposed() -> Matrix {
		let result = Matrix(rows: columns, columns: rows)
		Numerics.transpose(self, result)
		return result
	}
	
	// Matrix/Matric
	public static func -(lhs: Matrix, rhs: Matrix) -> Matrix { return Numerics.subtract(lhs, rhs) }
//	public static func +(lhs: Matrix, rhs: Matrix) -> Matrix { return Numerics.add(lhs, rhs) }
	
	// Matrix/Vector
	public static func *(lhs: Matrix, rhs: Matrix) -> Matrix { return Numerics.multiply(lhs, rhs) }
	public static func *(lhs: Matrix, rhs: Vector) -> Vector { return Numerics.multiply(lhs, rhs) }
	// Matrix/Element
	public static func /(lhs: Matrix, rhs: Element) -> Matrix { return Numerics.multiply(lhs, 1.0/rhs) }
	public static func *(lhs: Matrix, rhs: Element) -> Matrix { return Numerics.multiply(lhs, rhs) }
	public static func *(lhs: Element, rhs: Matrix) -> Matrix { return Numerics.multiply(lhs, rhs) }
	
	public static func *=(lhs: Matrix, rhs: Element) { Numerics.multiply(lhs, rhs, lhs) }
	public static func /=(lhs: Matrix, rhs: Matrix) { Numerics.divide(lhs, rhs, lhs) }
}
