vim9script

# Indexed PNGs keep uploads small even on high-DPI terminals.
# Each line band is a stored DEFLATE block in its own IDAT chunk. Its CRC
# and Adler contribution can be reused when the line moves on screen.
def CrcTable(): list<number>
  var table: list<number> = []
  for byte in range(256)
    var crc = byte
    for _ in range(8)
      crc = xor(crc >> 1, and(crc, 1) ? 0xedb88320 : 0)
    endfor
    table->add(crc)
  endfor
  return table
enddef

const crc_table = CrcTable()

def BigEndian(value: number): blob
  return list2blob([value >> 24, and(value >> 16, 255), and(value >> 8, 255), and(value, 255)])
enddef

def Chunk(kind: blob, data: blob): blob
  var crc = 0xffffffff
  for byte in kind + data
    crc = xor(crc >> 8, crc_table[and(xor(crc, byte), 255)])
  endfor
  return BigEndian(len(data)) + kind + data + BigEndian(xor(crc, 0xffffffff))
enddef

export def Band(data: blob): list<any>
  var a = 0
  var b = 0
  for byte in data
    a += byte
    b += a
  endfor
  var size = len(data)
  var lo = and(size, 255)
  var hi = size >> 8
  var block = list2blob([0, lo, hi, xor(lo, 255), xor(hi, 255)]) + data
  return [Chunk(0z49444154, block), a % 65521, b % 65521, size]
enddef

export def Encode(width: number, height: number, palette: blob, bands: list<list<any>>, depth: number): blob
  var image = 0z89504E470D0A1A0A
    + Chunk(0z49484452, BigEndian(width) + BigEndian(height) + list2blob([depth]) + 0z03000000)
    + Chunk(0z504C5445, 0z000000 + palette)
    + Chunk(0z74524E53, 0z00)
    + Chunk(0z49444154, 0z7801)
  var a = 1
  var b = 0
  # Each band adds a five-byte block header and twelve bytes of PNG framing.
  var payload_length = height * (1 + (width * depth + 7) / 8) + len(bands) * (5 + 12)
  var offset = len(image)
  image += repeat(0z00, payload_length)
  for [block, band_a, band_b, size] in bands
    image[offset : offset + len(block) - 1] = block
    offset += len(block)
    b = (b + band_b + a * size) % 65521
    a = (a + band_a) % 65521
  endfor
  # Empty final stored block, followed by the Adler checksum of the image.
  image += Chunk(0z49444154, 0z010000FFFF + BigEndian((b << 16) + a))
  return image + Chunk(0z49454E44, 0z)
enddef
