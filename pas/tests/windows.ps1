# PJA on Windows: the same streams as on Linux, round trips, and the CLI's
# refusals. Run from the folder windows_pkg.sh makes:
#   pwsh -NoProfile -File .\windows.ps1
# It writes results.txt next to itself.
$ErrorActionPreference = 'Continue'
$here = Split-Path -Parent $MyInvocation.MyCommand.Path
Set-Location $here
$out = Join-Path $here 'results.txt'
Set-Content -Path $out -Value "PJA Windows test $(Get-Date -Format s)" -Encoding utf8
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
& .\pja.exe a -q -th 1 -o win_full\ -- @inputs; Log "  rc $LASTEXITCODE"
SameAs 'win_full' $linFull 'full model, 1 thread: .pja identical to Linux'
& .\pja.exe a -q -th 1 --fast -o win_fast\ -- @inputs; Log "  rc $LASTEXITCODE"
SameAs 'win_fast' $linFast 'fast model, 1 thread: .pja identical to Linux'
& .\pja.exe a -q -th 4 -o win_full4\ -- @inputs
SameAs 'win_full4' $linFull 'full model, -th 4: identical'
$env:PJA_NOASM = '1'
& .\pja.exe a -q -th 1 --fast -o win_noasm\ -- @inputs
Remove-Item Env:PJA_NOASM
SameAs 'win_noasm' $linFast 'fast model without asm: identical'
& .\pja_ref.exe a -q -th 2 -o win_ref\ -- @inputs
SameAs 'win_ref' $linFull 'checked build, -th 2: identical'

Log '--- round trips'
$lf = Get-ChildItem -LiteralPath (Join-Path $here 'lin_full') | ForEach-Object { $_.FullName }
& .\pja.exe x -q -th 1 -o back_full\ -- @lf; Log "  rc $LASTEXITCODE"
SameAs 'back_full' $orig 'Linux .pja (full) extracted on Windows: the originals'
$lq = Get-ChildItem -LiteralPath (Join-Path $here 'lin_fast') | ForEach-Object { $_.FullName }
& .\pja.exe x -q -th 8 -o back_fast\ -- @lq; Log "  rc $LASTEXITCODE"
SameAs 'back_fast' $orig 'Linux .pja (fast) extracted with -th 8: the originals'

Log '--- the CLI'
New-Item -ItemType Directory -Force -Path cli | Out-Null
Copy-Item -LiteralPath 'in\grayscale.jpg' -Destination 'cli\g.jpg'
& .\pja.exe a -q 'cli\g.jpg'; Check ($LASTEXITCODE -eq 0) 'a into the same folder'
Set-Content -Path 'cli\g.jpg' -Value 'old'
& .\pja.exe x -q 'cli\g.pja' 2>$null; Check ($LASTEXITCODE -eq 1) 'x over an existing file: rc 1'
Check ((Get-Content 'cli\g.jpg') -eq 'old') '  the file is untouched'
& .\pja.exe x -q -f 'cli\g.pja'; Check ($LASTEXITCODE -eq 0) 'with -f: rc 0'
Check ((Sha 'cli\g.jpg') -eq $orig['grayscale.jpg']) '  replaced by the original'
$b = [IO.File]::ReadAllBytes((Join-Path $here 'cli\g.pja')); $b[20] = $b[20] -bxor 1
[IO.File]::WriteAllBytes((Join-Path $here 'cli\h.pja'), $b)
& .\pja.exe x -q 'cli\h.pja' 2>$null; Check ($LASTEXITCODE -eq 1) 'a hash bit changed: rc 1'
Check (-not (Test-Path 'cli\h.jpg')) '  nothing written under the name'
& .\pja.exe x -q --keep-corrupt 'cli\h.pja' 2>$null
Check ((Test-Path 'cli\h.jpg.corrupt') -and -not (Test-Path 'cli\h.jpg')) '--keep-corrupt: h.jpg.corrupt only'
& .\pja.exe x -q --max-output=100 -o 'cli\m.jpg' 'cli\g.pja' 2>$null
Check (($LASTEXITCODE -eq 1) -and -not (Test-Path 'cli\m.jpg')) '--max-output below the original: refused'
& .\pja.exe a -th4 x.jpg 2>$null; Check ($LASTEXITCODE -eq 2) 'glued -th4: rc 2'
& .\pja.exe list 'cli\g.pja' > cli\list.txt; Check ((Get-Content cli\list.txt) -match 'original') 'list'
New-Item -ItemType Directory -Force -Path 'cli\dir' | Out-Null
& .\pja.exe a -q 'cli\dir' 2>$null; Check ($LASTEXITCODE -eq 1) 'a directory as input: rc 1'

Log '--- names'
Check (Test-Path -LiteralPath 'win_full\fotoñandú.pja') 'a name in the ANSI code page: written under its own name'
Check (Test-Path -LiteralPath 'win_full\写真.pja') 'a name outside it: written under its own name'
Check (Test-Path -LiteralPath 'win_full\-dash.pja') 'a name that starts with a dash, after --'

Log "$($script:cells) cells, $($script:fails) failures"
