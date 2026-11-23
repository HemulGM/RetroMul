unit S16.Video;

interface

uses
  System.SysUtils, SegaArcade.Video;

const
  S16_WIDTH = SEGA_ARCADE_WIDTH;
  S16_HEIGHT = SEGA_ARCADE_HEIGHT;
  S16_FPS = 25174800 / (4 * 400 * 262);

type
  TS16Video = class(TSegaArcadeVideo)
  public
    constructor Create(const Tiles, Sprites: TBytes; RevisionA: Boolean; ROMBoard: Integer = -1);
  end;

implementation

constructor TS16Video.Create(const Tiles, Sprites: TBytes; RevisionA: Boolean; ROMBoard: Integer);
begin
  inherited Create(Tiles, Sprites, RevisionA, ROMBoard in [1, 2]);
end;

end.
