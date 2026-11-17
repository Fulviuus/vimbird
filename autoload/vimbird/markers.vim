vim9script

const priority = {add: 7, change: 8, delete: 9, quickfix: 11, warning: 13, error: 14}
const groups = {add: 'VimbirdGitAdd', change: 'VimbirdGitChange', delete: 'VimbirdGitDelete',
  quickfix: 'VimbirdQuickfix', warning: 'VimbirdWarning', error: 'VimbirdError'}

export def Row(lnum: number, rows: number, count: number): number
  return (min([count, max([1, lnum])]) * rows - 1) / count + 1
enddef

def GitLine(state: dict<any>, generation: number, message: string)
  if state.git_generation != generation
    return
  endif
  var parts = matchlist(message, '^@@ -\d\+\%(,\(\d\+\)\)\? +\(\d\+\)\%(,\(\d\+\)\)\? @@')
  if !empty(parts)
    var old_count = empty(parts[1]) ? 1 : str2nr(parts[1])
    var start = str2nr(parts[2])
    var size = empty(parts[3]) ? 1 : str2nr(parts[3])
    var kind = size == 0 ? 'delete' : (old_count == 0 ? 'add' : 'change')
    state.git_pending->add([max([1, start]), max([1, size]), kind])
  endif
enddef

def GitClosed(state: dict<any>, generation: number, Notify: func, _channel: channel)
  if state.git_generation == generation
    state.git_ranges = state.git_pending
    Notify()
  endif
enddef

export def RefreshGit(state: dict<any>, buf: number, Notify: func, force: bool = false)
  var path = bufname(buf)
  if !empty(path)
    path = fnamemodify(path, ':p')
  endif
  var enabled = get(g:, 'vimbird_git_markers', 1)
  var key = [buf, path, enabled, getftime(path), getfsize(path)]
  if !force && state.git_key == key
    return
  endif
  var same_file = state.git_key[0 : 2] == key[0 : 2]
  state.git_key = key
  Stop(state)
  if !same_file
    state.git_ranges = []
  endif
  state.git_pending = []
  if !enabled || !filereadable(path) || !executable('git') || !has('job')
    return
  endif
  var args = ['git', '--literal-pathspecs', '-C', fnamemodify(path, ':h'), 'diff',
    '--no-ext-diff', '--no-textconv', '--no-color', '--unified=0', 'HEAD', '--', fnamemodify(path, ':t')]
  var generation = state.git_generation
  state.git_job = job_start(args, {in_io: 'null', err_io: 'null',
    out_cb: (_, message) => GitLine(state, generation, message),
    close_cb: (ch) => GitClosed(state, generation, Notify, ch)})
enddef

export def Stop(state: dict<any>)
  state.git_generation += 1
  if state.git_job != null_job && job_status(state.git_job) ==# 'run'
    job_stop(state.git_job)
  endif
enddef

def Kind(name: string): string
  if name =~? 'gitgutter\|gitsigns\|signify'
    if name =~? 'delete'
      return 'delete'
    endif
    return name =~? 'add' ? 'add' : 'change'
  endif
  if name =~? 'diagnostic\|^ale\|^coc\|^syntastic\|^lsp'
    if name =~? 'error'
      return 'error'
    elseif name =~? 'warn'
      return 'warning'
    endif
  endif
  return ''
enddef

def Quickfix(state: dict<any>, source: number, buf: number)
  var qf = getqflist({id: 0, changedtick: 0})
  var local = getloclist(source, {id: 0, changedtick: 0})
  var key = [buf, qf, local]
  if state.quickfix_key == key
    return
  endif
  state.quickfix_key = key
  state.quickfix_positions = []
  for item in getqflist() + getloclist(source)
    if item.bufnr == buf && item.lnum > 0 && item.valid
      var kind = item.type ==? 'E' ? 'error' : (item.type ==? 'W' ? 'warning' : 'quickfix')
      state.quickfix_positions->add([item.lnum, kind])
    endif
  endfor
enddef

export def Draw(state: dict<any>, rows: number, count: number, buf: number)
  var git = get(g:, 'vimbird_git_markers', 1)
  var diagnostics = get(g:, 'vimbird_diagnostic_markers', 1)
  if diagnostics
    Quickfix(state, state.source, buf)
  endif
  var signs = git || diagnostics ? get(sign_getplaced(buf, {group: '*'}), 0, {signs: []}).signs : []
  var key = [buf, rows, count, signs, git ? state.git_ranges : [], diagnostics ? state.quickfix_positions : [], git, diagnostics]
  if state.marker_key == key
    return
  endif
  state.marker_key = key
  for id in state.marker_matches
    matchdelete(id, state.win)
  endfor
  state.marker_matches = []

  var positions: dict<list<list<number>>> = {}
  var git_signs = []
  for sign in signs
    var kind = Kind(sign.name)
    if empty(kind)
      continue
    endif
    var is_git = priority[kind] <= priority.delete
    if is_git && git
      git_signs->add([sign.lnum, 1, kind])
    elseif !is_git && diagnostics
      extend(positions, { [kind]: [] }, 'keep')
      positions[kind]->add([Row(sign.lnum, rows, count), 1, 1])
    endif
  endfor
  if git
    var ranges = empty(git_signs) ? state.git_ranges : git_signs
    for [first, size, kind] in ranges
      extend(positions, { [kind]: [] }, 'keep')
      for row in range(Row(first, rows, count), Row(first + size - 1, rows, count))
        positions[kind]->add([row, 1, 1])
      endfor
    endfor
  endif
  if diagnostics
    for [lnum, kind] in state.quickfix_positions
      extend(positions, { [kind]: [] }, 'keep')
      positions[kind]->add([Row(lnum, rows, count), 1, 1])
    endfor
  endif
  for [kind, locations] in items(positions)
    var unique = uniq(sort(locations, (left, right) => left[0] - right[0]), (left, right) => left[0] - right[0])
    state.marker_matches->add(matchaddpos(groups[kind], unique, priority[kind], -1, {window: state.win}))
  endfor
enddef
