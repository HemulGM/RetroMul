unit PC.Sound.OPL2;

interface

uses
  PC.Sound.OPL;

type
  // YM3812, nine two-operator channels, mono output.
  TOPL2 = class(TOPLSound)
  public
    constructor Create(Clock: Integer = 3579545; SampleRate: Integer = 44100);
  end;

implementation

constructor TOPL2.Create(Clock, SampleRate: Integer);
begin
  CreateChip(False, Clock, SampleRate);
end;

end.

