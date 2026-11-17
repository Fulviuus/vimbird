vim9script

const esc = "\e"
const apc = esc .. '_G'
const st = esc .. '\'
const tile = nr2char(0x10eeee)
# Row and column diacritics in Kitty's protocol order.
const marks = [
  0x0305, 0x030D, 0x030E, 0x0310, 0x0312, 0x033D, 0x033E, 0x033F,
  0x0346, 0x034A, 0x034B, 0x034C, 0x0350, 0x0351, 0x0352, 0x0357,
  0x035B, 0x0363, 0x0364, 0x0365, 0x0366, 0x0367, 0x0368, 0x0369,
  0x036A, 0x036B, 0x036C, 0x036D, 0x036E, 0x036F, 0x0483, 0x0484,
  0x0485, 0x0486, 0x0487, 0x0592, 0x0593, 0x0594, 0x0595, 0x0597,
  0x0598, 0x0599, 0x059C, 0x059D, 0x059E, 0x059F, 0x05A0, 0x05A1,
  0x05A8, 0x05A9, 0x05AB, 0x05AC, 0x05AF, 0x05C4, 0x0610, 0x0611,
  0x0612, 0x0613, 0x0614, 0x0615, 0x0616, 0x0617, 0x0657, 0x0658,
  0x0659, 0x065A, 0x065B, 0x065D, 0x065E, 0x06D6, 0x06D7, 0x06D8,
  0x06D9, 0x06DA, 0x06DB, 0x06DC, 0x06DF, 0x06E0, 0x06E1, 0x06E2,
  0x06E4, 0x06E7, 0x06E8, 0x06EB, 0x06EC, 0x0730, 0x0732, 0x0733,
  0x0735, 0x0736, 0x073A, 0x073D, 0x073F, 0x0740, 0x0741, 0x0743,
  0x0745, 0x0747, 0x0749, 0x074A, 0x07EB, 0x07EC, 0x07ED, 0x07EE,
  0x07EF, 0x07F0, 0x07F1, 0x07F3, 0x0816, 0x0817, 0x0818, 0x0819,
  0x081B, 0x081C, 0x081D, 0x081E, 0x081F, 0x0820, 0x0821, 0x0822,
  0x0823, 0x0825, 0x0826, 0x0827, 0x0829, 0x082A, 0x082B, 0x082C,
  0x082D, 0x0951, 0x0953, 0x0954, 0x0F82, 0x0F83, 0x0F86, 0x0F87,
  0x135D, 0x135E, 0x135F, 0x17DD, 0x193A, 0x1A17, 0x1A75, 0x1A76,
  0x1A77, 0x1A78, 0x1A79, 0x1A7A, 0x1A7B, 0x1A7C, 0x1B6B, 0x1B6D,
  0x1B6E, 0x1B6F, 0x1B70, 0x1B71, 0x1B72, 0x1B73, 0x1CD0, 0x1CD1,
  0x1CD2, 0x1CDA, 0x1CDB, 0x1CE0, 0x1DC0, 0x1DC1, 0x1DC3, 0x1DC4,
  0x1DC5, 0x1DC6, 0x1DC7, 0x1DC8, 0x1DC9, 0x1DCB, 0x1DCC, 0x1DD1,
  0x1DD2, 0x1DD3, 0x1DD4, 0x1DD5, 0x1DD6, 0x1DD7, 0x1DD8, 0x1DD9,
  0x1DDA, 0x1DDB, 0x1DDC, 0x1DDD, 0x1DDE, 0x1DDF, 0x1DE0, 0x1DE1,
]
export const MAX_ROWS = len(marks)

export def Tiles(columns: number, rows: number): list<string>
  var lines: list<string> = []
  for row in range(rows)
    var prefix = tile .. nr2char(marks[row])
    var tiles = ' '
    for col in range(columns)
      tiles ..= prefix .. nr2char(marks[col])
    endfor
    lines->add(tiles)
  endfor
  return lines
enddef

var file_transport = 0
var trial_files: list<string> = []

def DirectWire(placement: string, image: blob): string
  var encoded = base64_encode(image)
  var commands: list<string> = []
  for offset in range(0, len(encoded) - 1, 4096)
    var header = offset == 0 ? placement .. ',t=d,' : ''
    var more = offset + 4096 < len(encoded) ? 1 : 0
    commands->add(apc .. header .. 'm=' .. more .. ';' .. strpart(encoded, offset, 4096) .. st)
  endfor
  return join(commands, '')
enddef

def CheckFileTransfer(_timer: number)
  var first = trial_files[0]
  var accepted = !filereadable(first)
  file_transport = accepted ? 1 : -1
  if !accepted
    for path in trial_files
      delete(path)
    endfor
  endif
  trial_files = []
  if !accepted
    vimbird#RetryTransport()
  endif
enddef

def FileWire(placement: string, image: blob): string
  var preference = get(g:, 'vimbird_transport', 'auto')
  var local = empty($SSH_CONNECTION) && empty($SSH_CLIENT) && empty($SSH_TTY)
  var known = &term =~# '^xterm-\%(kitty\|ghostty\)$' || $TERM_PROGRAM ==# 'ghostty'
  if file_transport < 0 || !(preference ==# 'file' || (preference ==# 'auto' && local && known))
    return ''
  endif
  var path = tempname() .. '-tty-graphics-protocol.png'
  try
    if writefile(image, path, 'bS') != 0
      return ''
    endif
  catch /^Vim/
    delete(path)
    return ''
  endtry
  if file_transport == 0
    trial_files->add(path)
    if len(trial_files) == 1
      timer_start(400, CheckFileTransfer)
    endif
  endif
  return apc .. placement .. ',t=t,S=' .. len(image) .. ';' .. base64_encode(str2blob([path])) .. st
enddef

export def Upload(id: number, image: blob, columns: number, rows: number): dict<any>
  var started = reltime()
  var placement = printf('a=T,f=100,U=1,i=%d,c=%d,r=%d,q=2', id, columns, rows)
  var wire = FileWire(placement, image)
  var medium = 'file'
  if empty(wire)
    medium = 'direct'
    wire = DirectWire(placement, image)
  endif
  var writing = reltime()
  if writefile([wire], '/dev/tty', 'b') != 0
    throw 'Vimbird: could not write to the terminal'
  endif
  return {bytes: len(wire), medium: medium, encode_ms: reltimefloat(reltime(started, writing)) * 1000,
    write_ms: reltimefloat(reltime(writing)) * 1000}
enddef

export def Delete(id: number)
  writefile([printf('%sa=d,d=I,i=%d,q=2%s', apc, id, st)], '/dev/tty', 'b')
enddef
