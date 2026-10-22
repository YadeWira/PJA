# PJA on Windows: the same streams as on Linux, round trips, and the CLI's
# refusals. Run from the folder windows_pkg.sh makes:
#   pwsh -NoProfile -File .\windows.ps1                                   (64-bit)
#   pwsh -NoProfile -File .\windows.ps1 -Exe pja32.exe -Ref pja32_ref.exe  (32-bit)
# It writes results-<exe>.txt next to itself.
param([string]$Exe = 'pja.exe', [string]$Ref = 'pja_ref.exe')
$ErrorActionPreference = 'Continue'
$here = Split-Path -Parent $MyInvocation.MyCommand.Path
Set-Location $here
$pja = Join-Path $here $Exe; $pjaRef = Join-Path $here $Ref
Remove-Item -Recurse -Force win_*, back_*, cli -ErrorAction SilentlyContinue
$out = Join-Path $here "results-$Exe.txt"
Set-Content -Path $out -Value "PJA Windows test, $Exe and $Ref, $(Get-Date -Format s)" -Encoding utf8
$script:fails = 0; $script:cells = 0
function Log($s) { Add-Content -Path $out -Value $s -Encoding utf8 }
function Check($ok, $what) {
  $script:cells++
  if ($ok) { Log "  ok    $what" } else { $script:fails++; Log "  FAIL  $what" }
}
function Sha($p) { (Get-FileHash -LiteralPath $p -Algorithm SHA256).Hash.ToLower() }
function LoadSums($f) {
  $m = @{}
  foreach ($l in [IO.File]::ReadAllLines((Join-Path $here $f), [Text.Encoding]::UTF8)) {
    if ($l.Length -gt 66) { $m[$l.Substring(66)] = $l.Substring(0, 64) }
  }
  return $m
}
function SameAs($dir, $sums, $what) {
  $same = 0; $total = 0; $bad = @()
  foreach ($k in $sums.Keys) {
    $total++
    $p = Join-Path $dir $k
    if ((Test-Path -LiteralPath $p) -and ((Sha $p) -eq $sums[$k])) { $same++ } else { $bad += $k }
  }
  Check ($same -eq $total) "$what ($same of $total)"
  foreach ($b in $bad | Select-Object -First 5) { Log "        differs or missing: $b" }
}
# tar on Windows unpacks a UTF-8 name as OEM characters: the non-ASCII
# sample is made here instead, as a copy (its .pja does not depend on the name)
foreach ($n in 'fotoñandú', '写真') {
  Copy-Item -LiteralPath 'in\grayscale.jpg' -Destination "in\$n.jpg"
  Copy-Item -LiteralPath 'lin_full\grayscale.pja' -Destination "lin_full\$n.pja"
  Copy-Item -LiteralPath 'lin_fast\grayscale.pja' -Destination "lin_fast\$n.pja"
}
$inputs = Get-ChildItem -LiteralPath (Join-Path $here 'in') | ForEach-Object { $_.FullName }
$linFull = LoadSums 'lin_full.sha256'; $linFast = LoadSums 'lin_fast.sha256'; $orig = LoadSums 'in.sha256'
foreach ($n in 'fotoñandú', '写真') {
  $linFull["$n.pja"] = $linFull['grayscale.pja']; $linFast["$n.pja"] = $linFast['grayscale.pja']
  $orig["$n.jpg"] = $orig['grayscale.jpg']
}
Log "inputs: $($inputs.Count)"

Log '--- the same streams as Linux'
& $pja a -q -th 1 -o win_full\ -- @inputs; Log "  rc $LASTEXITCODE"
SameAs 'win_full' $linFull 'full model, 1 thread: .pja identical to Linux'
& $pja a -q -th 1 --fast -o win_fast\ -- @inputs; Log "  rc $LASTEXITCODE"
SameAs 'win_fast' $linFast 'fast model, 1 thread: .pja identical to Linux'
& $pja a -q -th 4 -o win_full4\ -- @inputs
SameAs 'win_full4' $linFull 'full model, -th 4: identical'
$env:PJA_NOASM = '1'
& $pja a -q -th 1 --fast -o win_noasm\ -- @inputs
Remove-Item Env:PJA_NOASM
SameAs 'win_noasm' $linFast 'fast model without asm: identical'
& $pjaRef a -q -th 2 -o win_ref\ -- @inputs
SameAs 'win_ref' $linFull 'checked build, -th 2: identical'

Log '--- round trips'
$lf = Get-ChildItem -LiteralPath (Join-Path $here 'lin_full') | ForEach-Object { $_.FullName }
& $pja x -q -th 1 -o back_full\ -- @lf; Log "  rc $LASTEXITCODE"
SameAs 'back_full' $orig 'Linux .pja (full) extracted on Windows: the originals'
$lq = Get-ChildItem -LiteralPath (Join-Path $here 'lin_fast') | ForEach-Object { $_.FullName }
& $pja x -q -th 8 -o back_fast\ -- @lq; Log "  rc $LASTEXITCODE"
SameAs 'back_fast' $orig 'Linux .pja (fast) extracted with -th 8: the originals'

Log '--- the CLI'
New-Item -ItemType Directory -Force -Path cli | Out-Null
Copy-Item -LiteralPath 'in\grayscale.jpg' -Destination 'cli\g.jpg'
& $pja a -q 'cli\g.jpg'; Check ($LASTEXITCODE -eq 0) 'a into the same folder'
Set-Content -Path 'cli\g.jpg' -Value 'old'
& $pja x -q 'cli\g.pja' 2>$null; Check ($LASTEXITCODE -eq 1) 'x over an existing file: rc 1'
Check ((Get-Content 'cli\g.jpg') -eq 'old') '  the file is untouched'
& $pja x -q -f 'cli\g.pja'; Check ($LASTEXITCODE -eq 0) 'with -f: rc 0'
Check ((Sha 'cli\g.jpg') -eq $orig['grayscale.jpg']) '  replaced by the original'
$b = [IO.File]::ReadAllBytes((Join-Path $here 'cli\g.pja')); $b[20] = $b[20] -bxor 1
[IO.File]::WriteAllBytes((Join-Path $here 'cli\h.pja'), $b)
& $pja x -q 'cli\h.pja' 2>$null; Check ($LASTEXITCODE -eq 1) 'a hash bit changed: rc 1'
Check (-not (Test-Path 'cli\h.jpg')) '  nothing written under the name'
& $pja x -q --keep-corrupt 'cli\h.pja' 2>$null
Check ((Test-Path 'cli\h.jpg.corrupt') -and -not (Test-Path 'cli\h.jpg')) '--keep-corrupt: h.jpg.corrupt only'
& $pja x -q --max-output=100 -o 'cli\m.jpg' 'cli\g.pja' 2>$null
Check (($LASTEXITCODE -eq 1) -and -not (Test-Path 'cli\m.jpg')) '--max-output below the original: refused'
& $pja a -th4 x.jpg 2>$null; Check ($LASTEXITCODE -eq 2) 'glued -th4: rc 2'
& $pja list 'cli\g.pja' > cli\list.txt; Check ((Get-Content cli\list.txt) -match 'original') 'list'
$o = & $pja a -f 'in\gray8.jls' -o 'cli\st.pja'
Check (($LASTEXITCODE -eq 0) -and ($o -match 'stored as is')) 'a file the codec cannot shrink: stored as is'
Set-Content -Path 'cli\plain' -Value 'x'
$e = & $pja a 'in\grayscale.jpg' -o 'cli\plain\x.pja' 2>&1 | Out-String
Check (($LASTEXITCODE -eq 1) -and ($e -match 'could not write it: [A-Za-z]')) "a write the system refuses, in its words: $($e.Trim())"
New-Item -ItemType Directory -Force -Path 'cli\dir' | Out-Null
& $pja a -q 'cli\dir' 2>$null; Check ($LASTEXITCODE -eq 1) 'a directory as input: rc 1'

Log '--- names'
Check (Test-Path -LiteralPath 'win_full\fotoñandú.pja') 'a name in the ANSI code page: written under its own name'
Check (Test-Path -LiteralPath 'win_full\写真.pja') 'a name outside it: written under its own name'
Check (Test-Path -LiteralPath 'win_full\-dash.pja') 'a name that starts with a dash, after --'

Log "$($script:cells) cells, $($script:fails) failures"
