{ Format limits. The numbers come from doc/POLICY.md, where each one says
  where it comes from. }
unit pjalimits;

{$I pja.inc}
{$ifopt R-}{$fatal pjalimits: range checks ($R+) are mandatory}{$endif}
{$ifopt Q-}{$fatal pjalimits: overflow checks ($Q+) are mandatory}{$endif}

interface

const
  { The smallest codec stream: its version byte and the length of its
    header stream. No payload can be smaller. }
  MIN_PAYLOAD = 5;

  { How many times its payload a declared original size may be. Measured on
    19/10/2026: photos 1.3x, a 24 MP solid-colour JPEG 160x, a JPEG with
    4 MB of zeros after its end 2038x (the raw bytes compress to almost
    nothing). The cap is there so that a tiny file cannot declare a huge
    output before anything is decoded; 65536 leaves room above what was
    measured, and the user's --max-output still applies. }
  MAX_EXPANSION_RATIO = 65536;

implementation

end.
