unit GB.Sound.Channel;

interface

type
  TIntegerArray = array of Integer;

type
  TBaseChannel = class
  private
    FEnabled: Boolean;
    FLengthEnabled: Boolean;
    FLength: Integer;
    FFrequency: Double;
    FIndex: Integer;
    FWave: TIntegerArray;
  public
    function IsEnabled: Boolean;
    procedure SetEnabled(Value: Boolean);
    function IsLengthEnabled: Boolean;
    procedure SetLengthEnabled(Value: Boolean);
    function GetLength: Integer;
    procedure SetLength(Value: Integer);
    procedure DecLength;
    function GetFrequency: Double;
    procedure SetFrequency(Value: Double);
    function GetIndex: Integer;
    procedure SetIndex(Value: Integer);
    procedure IncIndex;
    function GetWave: TIntegerArray;
    function GetWaveValue(Index: Integer): Integer;
    procedure SetWave(Value: TIntegerArray);
  end;

type
  TEnvelope = class
  private
    FBase: Integer;
    FDirection: Integer;
    FStepLength: Integer;
    FIndex: Integer;
  public
    function GetBase: Integer;
    procedure SetBase(Value: Integer);
    function GetDirection: Integer;
    procedure SetDirection(Value: Integer);
    function GetStepLength: Integer;
    procedure SetStepLength(Value: Integer);
    function GetIndex: Integer;
    procedure SetIndex(Value: Integer);
    procedure HandleSweep;
  end;

const
  SoundWavePattern: array[0..3, 0..31] of Integer = (
    (1, 1, 1, 1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1),
    (1, 1, 1, 1, 1, 1, 1, 1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1),
    (1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1),
    (1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, -1, -1, -1, -1, -1, -1, -1, -1));

type
  TSquareWaveChannel = class(TBaseChannel)
  private
    FVolume: TEnvelope;
    FGBFrequency: Integer;
    FSweepIndex: Integer;
    FSweepLength: Integer;
    FSweepDirection: Integer;
    FSweepShift: Integer;
  public
    function GetVolume: TEnvelope;
    procedure SetVolume(Value: TEnvelope);
    function GetGBFrequency: Integer;
    procedure SetGBFrequency(Value: Integer);
    function GetSweepIndex: Integer;
    procedure SetSweepIndex(Value: Integer);
    procedure DecSweepIndex;
    function GetSweepLength: Integer;
    procedure SetSweepLength(Value: Integer);
    function GetSweepDirection: Integer;
    procedure SetSweepDirection(Value: Integer);
    function GetSweepShift: Integer;
    procedure SetSweepShift(Value: Integer);
    procedure SetWaveDuty(Value: Integer);
    destructor Destroy; override;
  end;

type
  TWaveChannel = class(TBaseChannel)
  end;

const
  Noise7: array[0..15] of Integer = ($fd, $f3, $d7, $0d, $d3, $15, $82, $f1, $db, $25, $21, $39, $68, $8c, $d5, $00);

const
  Noise15: array[0..4095] of Integer = (
    $ff, $fd, $ff, $f3, $ff, $d7, $ff, $0f, $fd, $df, $f3, $3f, $d5, $7f, $00, $fd,
    $fd, $f3, $f3, $d7, $d7, $0f, $0d, $dd, $d3, $33, $15, $55, $80, $02, $ff, $f1,
    $ff, $db, $ff, $27, $fd, $2f, $f1, $1f, $d9, $bf, $2a, $7d, $02, $f1, $f1, $db,
    $db, $27, $25, $2d, $21, $11, $39, $99, $6a, $a8, $80, $0c, $ff, $d5, $ff, $03,
    $fd, $f7, $f3, $cf, $d7, $5f, $0c, $3d, $d7, $73, $0c, $d5, $d5, $03, $01, $f5,
    $fb, $c3, $e7, $77, $ac, $ce, $15, $5b, $80, $26, $ff, $29, $fd, $0b, $f1, $c7,
    $db, $6f, $24, $9d, $24, $b1, $24, $59, $26, $29, $2b, $09, $05, $c9, $e3, $4b,
    $b4, $46, $46, $6a, $6a, $82, $80, $f0, $fd, $dd, $f3, $33, $d5, $57, $00, $0d,
    $ff, $d3, $ff, $17, $fd, $8f, $f2, $df, $d1, $3f, $19, $7d, $a8, $f2, $0d, $d3,
    $d3, $17, $15, $8d, $82, $d2, $f1, $11, $d9, $9b, $2a, $a5, $00, $21, $ff, $3b,
    $fd, $67, $f0, $af, $dc, $1f, $37, $bd, $4e, $70, $5a, $de, $21, $3b, $39, $65,
    $68, $a0, $8c, $3c, $d7, $75, $0c, $c1, $d5, $7b, $00, $e5, $fd, $a3, $f2, $37,
    $d3, $4f, $14, $5d, $86, $32, $eb, $51, $84, $1a, $e7, $a1, $ae, $3a, $1b, $63,
    $a4, $b6, $24, $4b, $26, $45, $2a, $61, $02, $b9, $f0, $6b, $de, $87, $38, $ed,
    $6d, $90, $92, $9c, $90, $b4, $9c, $44, $b6, $64, $4a, $a6, $40, $2a, $7f, $02,
    $fd, $f1, $f3, $db, $d7, $27, $0d, $2d, $d1, $13, $19, $95, $aa, $82, $00, $f3,
    $fd, $d7, $f3, $0f, $d5, $df, $03, $3d, $f5, $73, $c0, $d7, $7d, $0c, $f1, $d5,
    $db, $03, $25, $f5, $23, $c1, $37, $79, $4c, $e8, $55, $8e, $02, $db, $f1, $27,
    $d9, $2f, $29, $1d, $09, $b1, $ca, $5b, $42, $24, $73, $26, $d5, $29, $01, $09,
    $f9, $cb, $eb, $47, $84, $6e, $e6, $99, $a8, $aa, $0c, $03, $d7, $f7, $0f, $cd,
    $df, $53, $3c, $15, $77, $80, $ce, $fd, $59, $f0, $2b, $df, $07, $3d, $ed, $73,
    $90, $d6, $9d, $08, $b1, $cc, $5b, $56, $24, $0b, $27, $c5, $2f, $61, $1c, $b9,
    $b4, $6a, $46, $82, $68, $f2, $8d, $d0, $d3, $1d, $15, $b1, $82, $5a, $f2, $21,
    $d3, $3b, $15, $65, $80, $a2, $fc, $31, $f7, $5b, $cc, $27, $57, $2c, $0d, $17,
    $d1, $8f, $1a, $dd, $a1, $32, $39, $53, $68, $14, $8f, $84, $de, $e5, $39, $a1,
    $6a, $38, $83, $6c, $f4, $95, $c4, $83, $64, $f4, $a5, $c4, $23, $67, $34, $ad,
    $44, $10, $67, $9e, $ae, $b8, $18, $6f, $ae, $9e, $18, $bb, $ac, $66, $16, $ab,
    $88, $06, $cf, $e9, $5f, $88, $3e, $cf, $79, $5c, $e8, $35, $8f, $42, $dc, $71,
    $36, $d9, $49, $28, $49, $0e, $49, $da, $4b, $22, $45, $32, $61, $52, $b8, $10,
    $6f, $9e, $9e, $b8, $b8, $6c, $6e, $96, $98, $88, $ac, $cc, $15, $57, $80, $0e,
    $ff, $d9, $ff, $2b, $fd, $07, $f1, $ef, $db, $9f, $26, $bd, $28, $71, $0e, $d9,
    $d9, $2b, $29, $05, $09, $e1, $cb, $bb, $46, $64, $6a, $a6, $80, $28, $ff, $0d,
    $fd, $d3, $f3, $17, $d5, $8f, $02, $dd, $f1, $33, $d9, $57, $28, $0d, $0f, $d1,
    $df, $1b, $3d, $a5, $72, $20, $d3, $3d, $15, $71, $80, $da, $fd, $21, $f1, $3b,
    $d9, $67, $28, $ad, $0c, $11, $d7, $9b, $0e, $a5, $d8, $23, $2f, $35, $1d, $41,
    $b0, $7a, $5e, $e2, $39, $b3, $6a, $54, $82, $04, $f3, $e5, $d7, $a3, $0e, $35,
    $db, $43, $24, $75, $26, $c1, $29, $79, $08, $e9, $cd, $8b, $52, $c4, $11, $67,
    $98, $ae, $ac, $18, $17, $af, $8e, $1e, $db, $b9, $26, $69, $2a, $89, $00, $c9,
    $fd, $4b, $f0, $47, $de, $6f, $3a, $9d, $60, $b0, $bc, $5c, $76, $36, $cb, $49,
    $44, $48, $66, $4e, $aa, $58, $02, $2f, $f3, $1f, $d5, $bf, $02, $7d, $f2, $f3,
    $d1, $d7, $1b, $0d, $a5, $d2, $23, $13, $35, $95, $42, $80, $70, $fe, $dd, $f9,
    $33, $e9, $57, $88, $0e, $cf, $d9, $5f, $28, $3d, $0f, $71, $dc, $db, $35, $25,
    $41, $20, $79, $3e, $e9, $79, $88, $ea, $cd, $81, $52, $f8, $11, $ef, $9b, $9e,
    $a6, $b8, $28, $6f, $0e, $9d, $d8, $b3, $2c, $55, $16, $01, $8b, $fa, $c7, $e1,
    $6f, $b8, $9e, $6c, $ba, $94, $60, $86, $bc, $e8, $75, $8e, $c2, $d9, $71, $28,
    $d9, $0d, $29, $d1, $0b, $19, $c5, $ab, $62, $04, $b3, $e4, $57, $a6, $0e, $2b,
    $db, $07, $25, $ed, $23, $91, $36, $99, $48, $a8, $4c, $0e, $57, $da, $0f, $23,
    $dd, $37, $31, $4d, $58, $50, $2e, $1f, $1b, $bd, $a6, $72, $2a, $d3, $01, $15,
    $f9, $83, $ea, $f7, $81, $ce, $fb, $59, $e4, $2b, $a7, $06, $2d, $eb, $13, $85,
    $96, $e2, $89, $b0, $ca, $5d, $42, $30, $73, $5e, $d4, $39, $07, $69, $ec, $8b,
    $94, $c6, $85, $68, $e0, $8d, $bc, $d2, $75, $12, $c1, $91, $7a, $98, $e0, $ad,
    $bc, $12, $77, $92, $ce, $91, $58, $98, $2c, $af, $14, $1d, $87, $b2, $ee, $51,
    $9a, $1a, $a3, $a0, $36, $3f, $4b, $7c, $44, $f6, $65, $ca, $a3, $40, $34, $7f,
    $46, $fc, $69, $f6, $8b, $c8, $c7, $4d, $6c, $50, $96, $1c, $8b, $b4, $c6, $45,
    $6a, $60, $82, $bc, $f0, $75, $de, $c3, $39, $75, $68, $c0, $8d, $7c, $d0, $f5,
    $1d, $c1, $b3, $7a, $54, $e2, $05, $b3, $e2, $57, $b2, $0e, $53, $da, $17, $23,
    $8d, $36, $d1, $49, $18, $49, $ae, $4a, $1a, $43, $a2, $76, $32, $cb, $51, $44,
    $18, $67, $ae, $ae, $18, $1b, $af, $a6, $1e, $2b, $bb, $06, $65, $ea, $a3, $80,
    $36, $ff, $49, $fc, $4b, $f6, $47, $ca, $6f, $42, $9c, $70, $b6, $dc, $49, $36,
    $49, $4a, $48, $42, $4e, $72, $5a, $d2, $21, $13, $39, $95, $6a, $80, $80, $fc,
    $fd, $f5, $f3, $c3, $d7, $77, $0c, $cd, $d5, $53, $00, $15, $ff, $83, $fe, $f7,
    $f9, $cf, $eb, $5f, $84, $3e, $e7, $79, $ac, $ea, $15, $83, $82, $f6, $f1, $c9,
    $db, $4b, $24, $45, $26, $61, $2a, $b9, $00, $69, $fe, $8b, $f8, $c7, $ed, $6f,
    $90, $9e, $9c, $b8, $b4, $6c, $46, $96, $68, $8a, $8c, $c0, $d5, $7d, $00, $f1,
    $fd, $db, $f3, $27, $d5, $2f, $01, $1d, $f9, $b3, $ea, $57, $82, $0e, $f3, $d9,
    $d7, $2b, $0d, $05, $d1, $e3, $1b, $b5, $a6, $42, $2a, $73, $02, $d5, $f1, $03,
    $d9, $f7, $2b, $cd, $07, $51, $ec, $1b, $97, $a6, $8e, $28, $db, $0d, $25, $d1,
    $23, $19, $35, $a9, $42, $08, $73, $ce, $d7, $59, $0c, $29, $d7, $0b, $0d, $c5,
    $d3, $63, $14, $b5, $84, $42, $e6, $71, $aa, $da, $01, $23, $f9, $37, $e9, $4f,
    $88, $5e, $ce, $39, $5b, $68, $24, $8f, $24, $dd, $25, $31, $21, $59, $38, $29,
    $6f, $08, $9d, $cc, $b3, $54, $54, $06, $07, $eb, $ef, $87, $9e, $ee, $b9, $98,
    $6a, $ae, $80, $18, $ff, $ad, $fe, $13, $fb, $97, $e6, $8f, $a8, $de, $0d, $3b,
    $d1, $67, $18, $ad, $ac, $12, $17, $93, $8e, $96, $d8, $89, $2c, $c9, $15, $49,
    $80, $4a, $fe, $41, $fa, $7b, $e2, $e7, $b1, $ae, $5a, $1a, $23, $a3, $36, $35,
    $4b, $40, $44, $7e, $66, $fa, $a9, $e0, $0b, $bf, $c6, $7f, $6a, $fc, $81, $f4,
    $fb, $c5, $e7, $63, $ac, $b6, $14, $4b, $86, $46, $ea, $69, $82, $8a, $f0, $c1,
    $dd, $7b, $30, $e5, $5d, $a0, $32, $3f, $53, $7c, $14, $f7, $85, $ce, $e3, $59,
    $b4, $2a, $47, $02, $6d, $f2, $93, $d0, $97, $1c, $8d, $b4, $d2, $45, $12, $61,
    $92, $ba, $90, $60, $9e, $bc, $b8, $74, $6e, $c6, $99, $68, $a8, $8c, $0c, $d7,
    $d5, $0f, $01, $dd, $fb, $33, $e5, $57, $a0, $0e, $3f, $db, $7f, $24, $fd, $25,
    $f1, $23, $d9, $37, $29, $4d, $08, $51, $ce, $1b, $5b, $a4, $26, $27, $2b, $2d,
    $05, $11, $e1, $9b, $ba, $a6, $60, $2a, $bf, $00, $7d, $fe, $f3, $f9, $d7, $eb,
    $0f, $85, $de, $e3, $39, $b5, $6a, $40, $82, $7c, $f2, $f5, $d1, $c3, $1b, $75,
    $a4, $c2, $25, $73, $20, $d5, $3d, $01, $71, $f8, $db, $ed, $27, $91, $2e, $99,
    $18, $a9, $ac, $0a, $17, $c3, $8f, $76, $dc, $c9, $35, $49, $40, $48, $7e, $4e,
    $fa, $59, $e2, $2b, $b3, $06, $55, $e2, $03, $83, $f6, $f7, $c9, $cf, $4b, $5c,
    $04, $3e, $67, $4e, $ac, $60, $17, $7f, $80, $fe, $c1, $f9, $7b, $e8, $e7, $87,
    $ae, $c2, $19, $93, $fc, $96, $08, $8f, $c0, $e7, $fc, $2c, $f0, $1d, $cc, $c3,
    $9e, $70, $00, $c0, $63, $7f, $54, $78, $40, $fe, $61, $9b, $f3, $40, $64, $3f,
    $0f, $f8, $2c, $f3, $3f, $99, $83, $2a, $79, $07, $cb, $e1, $9f, $cc, $ce, $60,
    $6c, $00, $84, $7c, $0f, $f5, $e8, $cf, $15, $66, $80, $b0, $f8, $5d, $f4, $33,
    $8a, $57, $44, $0c, $67, $d6, $af, $08, $1f, $cf, $b3, $5e, $54, $3a, $07, $63,
    $ec, $b7, $94, $4e, $86, $58, $ea, $2d, $83, $12, $f5, $91, $c2, $9b, $70, $a4,
    $dc, $25, $37, $21, $4d, $38, $51, $6e, $18, $9b, $ac, $a6, $14, $2b, $87, $06,
    $ed, $e9, $93, $8a, $96, $c0, $89, $7c, $c8, $f5, $4d, $c0, $53, $7e, $14, $fb,
    $85, $e6, $e3, $a9, $b6, $0a, $4b, $c2, $47, $72, $6c, $d2, $95, $10, $81, $9c,
    $fa, $b5, $e0, $43, $be, $76, $7a, $ca, $e1, $41, $b8, $7a, $6e, $e2, $99, $b0,
    $aa, $5c, $02, $37, $f3, $4f, $d4, $5f, $06, $3d, $eb, $73, $84, $d6, $e5, $09,
    $a1, $ca, $3b, $43, $64, $74, $a6, $c4, $29, $67, $08, $ad, $cc, $13, $57, $94,
    $0e, $87, $d8, $ef, $2d, $9d, $12, $b1, $90, $5a, $9e, $20, $bb, $3c, $65, $76,
    $a0, $c8, $3d, $4f, $70, $5c, $de, $35, $3b, $41, $64, $78, $a6, $ec, $29, $97,
    $0a, $8d, $c0, $d3, $7d, $14, $f1, $85, $da, $e3, $21, $b5, $3a, $41, $62, $78,
    $b2, $ec, $51, $96, $1a, $8b, $a0, $c6, $3d, $6b, $70, $84, $dc, $e5, $35, $a1,
    $42, $38, $73, $6e, $d4, $99, $04, $a9, $e4, $0b, $a7, $c6, $2f, $6b, $1c, $85,
    $b4, $e2, $45, $b2, $62, $52, $b2, $10, $53, $9e, $16, $bb, $88, $66, $ce, $a9,
    $58, $08, $2f, $cf, $1f, $5d, $bc, $32, $77, $52, $cc, $11, $57, $98, $0e, $af,
    $d8, $1f, $2f, $bd, $1e, $71, $ba, $da, $61, $22, $b9, $30, $69, $5e, $88, $38,
    $cf, $6d, $5c, $90, $34, $9f, $44, $bc, $64, $76, $a6, $c8, $29, $4f, $08, $5d,
    $ce, $33, $5b, $54, $24, $07, $27, $ed, $2f, $91, $1e, $99, $b8, $aa, $6c, $02,
    $97, $f0, $8f, $dc, $df, $35, $3d, $41, $70, $78, $de, $ed, $39, $91, $6a, $98,
    $80, $ac, $fc, $15, $f7, $83, $ce, $f7, $59, $cc, $2b, $57, $04, $0d, $e7, $d3,
    $af, $16, $1d, $8b, $b2, $c6, $51, $6a, $18, $83, $ac, $f6, $15, $cb, $83, $46,
    $f4, $69, $c6, $8b, $68, $c4, $8d, $64, $d0, $a5, $1c, $21, $b7, $3a, $4d, $62,
    $50, $b2, $1c, $53, $b6, $16, $4b, $8a, $46, $c2, $69, $72, $88, $d0, $cd, $1d,
    $51, $b0, $1a, $5f, $a2, $3e, $33, $7b, $54, $e4, $05, $a7, $e2, $2f, $b3, $1e,
    $55, $ba, $02, $63, $f2, $b7, $d0, $4f, $1e, $5d, $ba, $32, $63, $52, $b4, $10,
    $47, $9e, $6e, $ba, $98, $60, $ae, $bc, $18, $77, $ae, $ce, $19, $5b, $a8, $26,
    $0f, $2b, $dd, $07, $31, $ed, $5b, $90, $26, $9f, $28, $bd, $0c, $71, $d6, $db,
    $09, $25, $c9, $23, $49, $34, $49, $46, $48, $6a, $4e, $82, $58, $f2, $2d, $d3,
    $13, $15, $95, $82, $82, $f0, $f1, $dd, $db, $33, $25, $55, $20, $01, $3f, $f9,
    $7f, $e8, $ff, $8d, $fe, $d3, $f9, $17, $e9, $8f, $8a, $de, $c1, $39, $79, $68,
    $e8, $8d, $8c, $d2, $d5, $11, $01, $99, $fa, $ab, $e0, $07, $bf, $ee, $7f, $9a,
    $fe, $a1, $f8, $3b, $ef, $67, $9c, $ae, $b4, $18, $47, $ae, $6e, $1a, $9b, $a0,
    $a6, $3c, $2b, $77, $04, $cd, $e5, $53, $a0, $16, $3f, $8b, $7e, $c4, $f9, $65,
    $e8, $a3, $8c, $36, $d7, $49, $0c, $49, $d6, $4b, $0a, $45, $c2, $63, $72, $b4,
    $d0, $45, $1e, $61, $ba, $ba, $60, $62, $be, $b0, $78, $5e, $ee, $39, $9b, $6a,
    $a4, $80, $24, $ff, $25, $fd, $23, $f1, $37, $d9, $4f, $28, $5d, $0e, $31, $db,
    $5b, $24, $25, $27, $21, $2d, $39, $11, $69, $98, $8a, $ac, $c0, $15, $7f, $80,
    $fe, $fd, $f9, $f3, $eb, $d7, $87, $0e, $ed, $d9, $93, $2a, $95, $00, $81, $fc,
    $fb, $f5, $e7, $c3, $af, $76, $1c, $cb, $b5, $46, $40, $6a, $7e, $82, $f8, $f1,
    $ed, $db, $93, $26, $95, $28, $81, $0c, $f9, $d5, $eb, $03, $85, $f6, $e3, $c9,
    $b7, $4a, $4c, $42, $56, $72, $0a, $d3, $c1, $17, $79, $8c, $ea, $d5, $81, $02,
    $f9, $f1, $eb, $db, $87, $26, $ed, $29, $91, $0a, $99, $c0, $ab, $7c, $04, $f7,
    $e5, $cf, $a3, $5e, $34, $3b, $47, $64, $6c, $a6, $94, $28, $87, $0c, $ed, $d5,
    $93, $02, $95, $f0, $83, $dc, $f7, $35, $cd, $43, $50, $74, $1e, $c7, $b9, $6e,
    $68, $9a, $8c, $a0, $d4, $3d, $07, $71, $ec, $db, $95, $26, $81, $28, $f9, $0d,
    $e9, $d3, $8b, $16, $c5, $89, $62, $c8, $b1, $4c, $58, $56, $2e, $0b, $1b, $c5,
    $a7, $62, $2c, $b3, $14, $55, $86, $02, $eb, $f1, $87, $da, $ef, $21, $9d, $3a,
    $b1, $60, $58, $be, $2c, $7b, $16, $e5, $89, $a2, $ca, $31, $43, $58, $74, $2e,
    $c7, $19, $6d, $a8, $92, $0c, $93, $d4, $97, $04, $8d, $e4, $d3, $a5, $16, $21,
    $8b, $3a, $c5, $61, $60, $b8, $bc, $6c, $76, $96, $c8, $89, $4c, $c8, $55, $4e,
    $00, $5b, $fe, $27, $fb, $2f, $e5, $1f, $a1, $be, $3a, $7b, $62, $e4, $b1, $a4,
    $5a, $26, $23, $2b, $35, $05, $41, $e0, $7b, $be, $e6, $79, $aa, $ea, $01, $83,
    $fa, $f7, $e1, $cf, $bb, $5e, $64, $3a, $a7, $60, $2c, $bf, $14, $7d, $86, $f2,
    $e9, $d1, $8b, $1a, $c5, $a1, $62, $38, $b3, $6c, $54, $96, $04, $8b, $e4, $c7,
    $a5, $6e, $20, $9b, $3c, $a5, $74, $20, $c7, $3d, $6d, $70, $90, $dc, $9d, $34,
    $b1, $44, $58, $66, $2e, $ab, $18, $05, $af, $e2, $1f, $b3, $be, $56, $7a, $0a,
    $e3, $c1, $b7, $7a, $4c, $e2, $55, $b2, $02, $53, $f2, $17, $d3, $8f, $16, $dd,
    $89, $32, $c9, $51, $48, $18, $4f, $ae, $5e, $1a, $3b, $a3, $66, $34, $ab, $44,
    $04, $67, $e6, $af, $a8, $1e, $0f, $bb, $de, $67, $3a, $ad, $60, $10, $bf, $9c,
    $7e, $b6, $f8, $49, $ee, $4b, $9a, $46, $a2, $68, $32, $8f, $50, $dc, $1d, $37,
    $b1, $4e, $58, $5a, $2e, $23, $1b, $35, $a5, $42, $20, $73, $3e, $d5, $79, $00,
    $e9, $fd, $8b, $f2, $c7, $d1, $6f, $18, $9d, $ac, $b2, $14, $53, $86, $16, $eb,
    $89, $86, $ca, $e9, $41, $88, $7a, $ce, $e1, $59, $b8, $2a, $6f, $02, $9d, $f0,
    $b3, $dc, $57, $36, $0d, $4b, $d0, $47, $1e, $6d, $ba, $92, $60, $92, $bc, $90,
    $74, $9e, $c4, $b9, $64, $68, $a6, $8c, $28, $d7, $0d, $0d, $d1, $d3, $1b, $15,
    $a5, $82, $22, $f3, $31, $d5, $5b, $00, $25, $ff, $23, $fd, $37, $f1, $4f, $d8,
    $5f, $2e, $3d, $1b, $71, $a4, $da, $25, $23, $21, $35, $39, $41, $68, $78, $8e,
    $ec, $d9, $95, $2a, $81, $00, $f9, $fd, $eb, $f3, $87, $d6, $ef, $09, $9d, $ca,
    $b3, $40, $54, $7e, $06, $fb, $e9, $e7, $8b, $ae, $c6, $19, $6b, $a8, $86, $0c,
    $eb, $d5, $87, $02, $ed, $f1, $93, $da, $97, $20, $8d, $3c, $d1, $75, $18, $c1,
    $ad, $7a, $10, $e3, $9d, $b6, $b2, $48, $52, $4e, $12, $5b, $92, $26, $93, $28,
    $95, $0c, $81, $d4, $fb, $05, $e5, $e3, $a3, $b6, $36, $4b, $4a, $44, $42, $66,
    $72, $aa, $d0, $01, $1f, $f9, $bf, $ea, $7f, $82, $fe, $f1, $f9, $db, $eb, $27,
    $85, $2e, $e1, $19, $b9, $aa, $6a, $02, $83, $f0, $f7, $dd, $cf, $33, $5d, $54,
    $30, $07, $5f, $ec, $3f, $97, $7e, $8c, $f8, $d5, $ed, $03, $91, $f6, $9b, $c8,
    $a7, $4c, $2c, $57, $16, $0d, $8b, $d2, $c7, $11, $6d, $98, $92, $ac, $90, $14,
    $9f, $84, $be, $e4, $79, $a6, $ea, $29, $83, $0a, $f5, $c1, $c3, $7b, $74, $e4,
    $c5, $a5, $62, $20, $b3, $3c, $55, $76, $00, $cb, $fd, $47, $f0, $6f, $de, $9f,
    $38, $bd, $6c, $70, $96, $dc, $89, $34, $c9, $45, $48, $60, $4e, $be, $58, $7a,
    $2e, $e3, $19, $b5, $aa, $42, $02, $73, $f2, $d7, $d1, $0f, $19, $dd, $ab, $32,
    $05, $53, $e0, $17, $bf, $8e, $7e, $da, $f9, $21, $e9, $3b, $89, $66, $c8, $a9,
    $4c, $08, $57, $ce, $0f, $5b, $dc, $27, $37, $2d, $4d, $10, $51, $9e, $1a, $bb,
    $a0, $66, $3e, $ab, $78, $04, $ef, $e5, $9f, $a2, $be, $30, $7b, $5e, $e4, $39,
    $a7, $6a, $2c, $83, $14, $f5, $85, $c2, $e3, $71, $b4, $da, $45, $22, $61, $32,
    $b9, $50, $68, $1e, $8f, $b8, $de, $6d, $3a, $91, $60, $98, $bc, $ac, $74, $16,
    $c7, $89, $6e, $c8, $99, $4c, $a8, $54, $0e, $07, $db, $ef, $27, $9d, $2e, $b1,
    $18, $59, $ae, $2a, $1b, $03, $a5, $f6, $23, $cb, $37, $45, $4c, $60, $56, $be,
    $08, $7b, $ce, $e7, $59, $ac, $2a, $17, $03, $8d, $f6, $d3, $c9, $17, $49, $8c,
    $4a, $d6, $41, $0a, $79, $c2, $eb, $71, $84, $da, $e5, $21, $a1, $3a, $39, $63,
    $68, $b4, $8c, $44, $d6, $65, $0a, $a1, $c0, $3b, $7f, $64, $fc, $a5, $f4, $23,
    $c7, $37, $6d, $4c, $90, $54, $9e, $04, $bb, $e4, $67, $a6, $ae, $28, $1b, $0f,
    $a5, $de, $23, $3b, $35, $65, $40, $a0, $7c, $3e, $f7, $79, $cc, $eb, $55, $84,
    $02, $e7, $f1, $af, $da, $1f, $23, $bd, $36, $71, $4a, $d8, $41, $2e, $79, $1a,
    $e9, $a1, $8a, $3a, $c3, $61, $74, $b8, $c4, $6d, $66, $90, $a8, $9c, $0c, $b7,
    $d4, $4f, $06, $5d, $ea, $33, $83, $56, $f4, $09, $c7, $cb, $6f, $44, $9c, $64,
    $b6, $a4, $48, $26, $4f, $2a, $5d, $02, $31, $f3, $5b, $d4, $27, $07, $2d, $ed,
    $13, $91, $96, $9a, $88, $a0, $cc, $3d, $57, $70, $0c, $df, $d5, $3f, $01, $7d,
    $f8, $f3, $ed, $d7, $93, $0e, $95, $d8, $83, $2c, $f5, $15, $c1, $83, $7a, $f4,
    $e1, $c5, $bb, $62, $64, $b2, $a4, $50, $26, $1f, $2b, $bd, $06, $71, $ea, $db,
    $81, $26, $f9, $29, $e9, $0b, $89, $c6, $cb, $69, $44, $88, $64, $ce, $a5, $58,
    $20, $2f, $3f, $1d, $7d, $b0, $f2, $5d, $d2, $33, $13, $55, $94, $02, $87, $f0,
    $ef, $dd, $9f, $32, $bd, $50, $70, $1e, $df, $b9, $3e, $69, $7a, $88, $e0, $cd,
    $bd, $52, $70, $12, $df, $91, $3e, $99, $78, $a8, $ec, $0d, $97, $d2, $8f, $10,
    $dd, $9d, $32, $b1, $50, $58, $1e, $2f, $bb, $1e, $65, $ba, $a2, $60, $32, $bf,
    $50, $7c, $1e, $f7, $b9, $ce, $6b, $5a, $84, $20, $e7, $3d, $ad, $72, $10, $d3,
    $9d, $16, $b1, $88, $5a, $ce, $21, $5b, $38, $25, $6f, $20, $9d, $3c, $b1, $74,
    $58, $c6, $2d, $6b, $10, $85, $9c, $e2, $b5, $b0, $42, $5e, $72, $3a, $d3, $61,
    $14, $b9, $84, $6a, $e6, $81, $a8, $fa, $0d, $e3, $d3, $b7, $16, $4d, $8a, $52,
    $c2, $11, $73, $98, $d6, $ad, $08, $11, $cf, $9b, $5e, $a4, $38, $27, $6f, $2c,
    $9d, $14, $b1, $84, $5a, $e6, $21, $ab, $3a, $05, $63, $e0, $b7, $bc, $4e, $76,
    $5a, $ca, $21, $43, $38, $75, $6e, $c0, $99, $7c, $a8, $f4, $0d, $c7, $d3, $6f,
    $14, $9d, $84, $b2, $e4, $51, $a6, $1a, $2b, $a3, $06, $35, $eb, $43, $84, $76,
    $e6, $c9, $a9, $4a, $08, $43, $ce, $77, $5a, $cc, $21, $57, $38, $0d, $6f, $d0,
    $9f, $1c, $bd, $b4, $72, $46, $d2, $69, $12, $89, $90, $ca, $9d, $40, $b0, $7c,
    $5e, $f6, $39, $cb, $6b, $44, $84, $64, $e6, $a5, $a8, $22, $0f, $33, $dd, $57,
    $30, $0d, $5f, $d0, $3f, $1f, $7d, $bc, $f2, $75, $d2, $c3, $11, $75, $98, $c2,
    $ad, $70, $10, $df, $9d, $3e, $b1, $78, $58, $ee, $2d, $9b, $12, $a5, $90, $22,
    $9f, $30, $bd, $5c, $70, $36, $df, $49, $3c, $49, $76, $48, $ca, $4d, $42, $50,
    $72, $1e, $d3, $b9, $16, $69, $8a, $8a, $c0, $c1, $7d, $78, $f0, $ed, $dd, $93,
    $32, $95, $50, $80, $1c, $ff, $b5, $fe, $43, $fa, $77, $e2, $cf, $b1, $5e, $58,
    $3a, $2f, $63, $1c, $b5, $b4, $42, $46, $72, $6a, $d2, $81, $10, $f9, $9d, $ea,
    $b3, $80, $56, $fe, $09, $fb, $cb, $e7, $47, $ac, $6e, $16, $9b, $88, $a6, $cc,
    $29, $57, $08, $0d, $cf, $d3, $5f, $14, $3d, $87, $72, $ec, $d1, $95, $1a, $81,
    $a0, $fa, $3d, $e3, $73, $b4, $d6, $45, $0a, $61, $c2, $bb, $70, $64, $de, $a5,
    $38, $21, $6f, $38, $9d, $6c, $b0, $94, $5c, $86, $3e, $eb, $45, $84, $62, $e6,
    $b1, $a8, $5a, $0e, $23, $fb, $33, $25, $47, $20, $51, $3e, $19, $7f, $a8, $66,
    $0c, $fb, $d0, $07, $13, $e5, $9f, $83, $ce, $98, $58, $cd, $2e, $19, $14, $39,
    $86, $3f, $ff, $01, $85, $ff, $e1, $e1, $b3, $fc, $46, $63, $0f, $f8, $00, $53,
    $be, $1f, $fb, $c0, $e6, $7e, $bc, $f0, $01, $e3, $c3, $9f, $a6, $cc, $48, $7e,
    $40, $82, $9d, $f2, $ff, $d6, $07, $13, $f5, $87, $80, $0f, $71, $9c, $fd, $35,
    $61, $43, $f8, $78, $7e, $cf, $19, $99, $a8, $32, $00, $53, $fc, $17, $fb, $8f,
    $c6, $df, $a9, $3e, $09, $7b, $c8, $e7, $4d, $ac, $52, $16, $13, $8b, $96, $c6,
    $89, $68, $c8, $8d, $4c, $d0, $55, $1e, $01, $bb, $fa, $67, $e2, $af, $b0, $1e,
    $5f, $ba, $3e, $63, $7a, $b4, $e0, $45, $be, $62, $7a, $b2, $e0, $51, $be, $1a,
    $7b, $a2, $e6, $31, $ab, $5a, $04, $23, $e7, $37, $ad, $4e, $10, $5b, $9e, $26,
    $bb, $28, $65, $0e, $a1, $d8, $3b, $2f, $65, $1c, $a1, $b4, $3a, $47, $62, $6c,
    $b2, $94, $50, $86, $1c, $eb, $b5, $86, $42, $ea, $71, $82, $da, $f1, $21, $d9,
    $3b, $29, $65, $08, $a1, $cc, $3b, $57, $64, $0c, $a7, $d4, $2f, $07, $1d, $ed,
    $b3, $92, $56, $92, $08, $93, $cc, $97, $54, $8c, $04, $d7, $e5, $0f, $a1, $de,
    $3b, $3b, $65, $64, $a0, $a4, $3c, $27, $77, $2c, $cd, $15, $51, $80, $1a, $ff,
    $a1, $fe, $3b, $fb, $67, $e4, $af, $a4, $1e, $27, $bb, $2e, $65, $1a, $a1, $a0,
    $3a, $3f, $63, $7c, $b4, $f4, $45, $c6, $63, $6a, $b4, $80, $44, $fe, $65, $fa,
    $a3, $e0, $37, $bf, $4e, $7c, $5a, $f6, $21, $cb, $3b, $45, $64, $60, $a6, $bc,
    $28, $77, $0e, $cd, $d9, $53, $28, $15, $0f, $81, $de, $fb, $39, $e5, $6b, $a0,
    $86, $3c, $eb, $75, $84, $c2, $e5, $71, $a0, $da, $3d, $23, $71, $34, $d9, $45,
    $28, $61, $0e, $b9, $d8, $6b, $2e, $85, $18, $e1, $ad, $ba, $12, $63, $92, $b6,
    $90, $48, $9e, $4c, $ba, $54, $62, $06, $b3, $e8, $57, $8e, $0e, $db, $d9, $27,
    $29, $2d, $09, $11, $c9, $9b, $4a, $a4, $40, $26, $7f, $2a, $fd, $01, $f1, $fb,
    $db, $e7, $27, $ad, $2e, $11, $1b, $99, $a6, $aa, $28, $03, $0f, $f5, $df, $c3,
    $3f, $75, $7c, $c0, $f5, $7d, $c0, $f3, $7d, $d4, $f3, $05, $d5, $e3, $03, $b5,
    $f6, $43, $ca, $77, $42, $cc, $71, $56, $d8, $09, $2f, $c9, $1f, $49, $bc, $4a,
    $76, $42, $ca, $71, $42, $d8, $71, $2e, $d9, $19, $29, $a9, $0a, $09, $c3, $cb,
    $77, $44, $cc, $65, $56, $a0, $08, $3f, $cf, $7f, $5c, $fc, $35, $f7, $43, $cc,
    $77, $56, $cc, $09, $57, $c8, $0f, $4f, $dc, $5f, $36, $3d, $4b, $70, $44, $de,
    $65, $3a, $a1, $60, $38, $bf, $6c, $7c, $96, $f4, $89, $c4, $cb, $65, $44, $a0,
    $64, $3e, $a7, $78, $2c, $ef, $15, $9d, $82, $b2, $f0, $51, $de, $1b, $3b, $a5,
    $66, $20, $ab, $3c, $05, $77, $e0, $cf, $bd, $5e, $70, $3a, $df, $61, $3c, $b9,
    $74, $68, $c6, $8d, $68, $d0, $8d, $1c, $d1, $b5, $1a, $41, $a2, $7a, $32, $e3,
    $51, $b4, $1a, $47, $a2, $6e, $32, $9b, $50, $a4, $1c, $27, $b7, $2e, $4d, $1a,
    $51, $a2, $1a, $33, $a3, $56, $34, $0b, $47, $c4, $6f, $66, $9c, $a8, $b4, $0c,
    $47, $d6, $6f, $0a, $9d, $c0, $b3, $7c, $54, $f6, $05, $cb, $e3, $47, $b4, $6e,
    $46, $9a, $68, $a2, $8c, $30, $d7, $5d, $0c, $31, $d7, $5b, $0c, $25, $d7, $23,
    $0d, $35, $d1, $43, $18, $75, $ae, $c2, $19, $73, $a8, $d6, $0d, $0b, $d1, $c7,
    $1b, $6d, $a4, $92, $24, $93, $24, $95, $24, $81, $24, $f9, $25, $e9, $23, $89,
    $36, $c9, $49, $48, $48, $4e, $4e, $5a, $5a, $22, $23, $33, $35, $55, $40, $00
  );

type
  TNoiseChannel = class(TBaseChannel)
  private
    FVolume: TEnvelope;
    FShiftFrequency: Integer;
    FCounterStep: Integer;
    FDivisorRatio: Double;
  public
    function GetVolume: TEnvelope;
    procedure SetVolume(Value: TEnvelope);
    function GetShiftFrequency: Integer;
    procedure SetShiftFrequency(Value: Integer);
    function GetCounterStep: Integer;
    procedure SetCounterStep(Value: Integer);
    function GetDivisorRatio: Double;
    procedure SetDivisorRatio(Value: Double);
    destructor Destroy; override;
  end;

implementation

{ TBaseChannel }

procedure TBaseChannel.DecLength;
begin
  Dec(FLength);
end;

function TBaseChannel.GetFrequency: Double;
begin
  Result := FFrequency;
end;

function TBaseChannel.GetIndex: Integer;
begin
  Result := FIndex;
end;

function TBaseChannel.GetLength: Integer;
begin
  Result := FLength;
end;

function TBaseChannel.GetWave: TIntegerArray;
begin
  Result := Copy(FWave);
end;

function TBaseChannel.GetWaveValue(Index: Integer): Integer;
begin
  Result := FWave[Index];
end;

procedure TBaseChannel.IncIndex;
begin
  Inc(FIndex);
end;

function TBaseChannel.IsLengthEnabled: Boolean;
begin
  Result := FLengthEnabled;
end;

function TBaseChannel.IsEnabled: Boolean;
begin
  Result := FEnabled;
end;

procedure TBaseChannel.SetLengthEnabled(Value: Boolean);
begin
  FLengthEnabled := Value;
end;

procedure TBaseChannel.SetFrequency(Value: Double);
begin
  FFrequency := Value;
end;

procedure TBaseChannel.SetIndex(Value: Integer);
begin
  FIndex := Value;
end;

procedure TBaseChannel.SetLength(Value: Integer);
begin
  FLength := Value;
end;

procedure TBaseChannel.SetEnabled(Value: Boolean);
begin
  FEnabled := Value;
end;

procedure TBaseChannel.SetWave(Value: TIntegerArray);
begin
  FWave := Copy(Value);
end;

{ TEnvelope }

function TEnvelope.GetBase: Integer;
begin
  Result := FBase;
end;

function TEnvelope.GetDirection: Integer;
begin
  Result := FDirection;
end;

function TEnvelope.GetIndex: Integer;
begin
  Result := FIndex;
end;

function TEnvelope.GetStepLength: Integer;
begin
  Result := FStepLength;
end;

procedure TEnvelope.HandleSweep;
begin
  if FIndex <= 0 then
    Exit;
  Dec(FIndex);
  if FIndex <> 0 then
    Exit;
  FIndex := FStepLength;
  if (FDirection = 1) and (FBase < $F) then
    Inc(FBase)
  else if (FDirection = 0) and (FBase > 0) then
  begin
    Dec(FBase);
  end;
end;

procedure TEnvelope.SetBase(Value: Integer);
begin
  FBase := Value;
end;

procedure TEnvelope.SetDirection(Value: Integer);
begin
  FDirection := Value;
end;

procedure TEnvelope.SetIndex(Value: Integer);
begin
  FIndex := Value;
end;

procedure TEnvelope.SetStepLength(Value: Integer);
begin
  FStepLength := Value;
end;

{ TSquareWaveChannel }

procedure TSquareWaveChannel.DecSweepIndex;
begin
  Dec(FSweepIndex);
end;

destructor TSquareWaveChannel.Destroy;
begin
  FVolume.Free;
  inherited;
end;

function TSquareWaveChannel.GetGBFrequency: Integer;
begin
  Result := FGBFrequency;
end;

function TSquareWaveChannel.GetSweepDirection: Integer;
begin
  Result := FSweepDirection;
end;

function TSquareWaveChannel.GetSweepIndex: Integer;
begin
  Result := FSweepIndex;
end;

function TSquareWaveChannel.GetSweepLength: Integer;
begin
  Result := FSweepLength;
end;

function TSquareWaveChannel.GetSweepShift: Integer;
begin
  Result := FSweepShift;
end;

function TSquareWaveChannel.GetVolume: TEnvelope;
begin
  Result := FVolume;
end;

procedure TSquareWaveChannel.SetGBFrequency(Value: Integer);
begin
  FGBFrequency := Value;
end;

procedure TSquareWaveChannel.SetSweepDirection(Value: Integer);
begin
  FSweepDirection := Value;
end;

procedure TSquareWaveChannel.SetSweepIndex(Value: Integer);
begin
  FSweepIndex := Value;
end;

procedure TSquareWaveChannel.SetSweepLength(Value: Integer);
begin
  FSweepLength := Value;
end;

procedure TSquareWaveChannel.SetSweepShift(Value: Integer);
begin
  FSweepShift := Value;
end;

procedure TSquareWaveChannel.SetVolume(Value: TEnvelope);
begin
  if FVolume <> Value then
    FVolume.Free;
  FVolume := Value;
end;

procedure TSquareWaveChannel.SetWaveDuty(Value: Integer);
var
  Wave: TIntegerArray;
  I: Integer;
begin
  System.SetLength(Wave, Length(SoundWavePattern[Value]));
  for I := 0 to Length(SoundWavePattern[Value]) - 1 do
    Wave[I] := SoundWavePattern[Value][I];
  SetWave(Wave);
end;

{ TNoiseChannel }

destructor TNoiseChannel.Destroy;
begin
  FVolume.Free;
  inherited;
end;

function TNoiseChannel.GetCounterStep: Integer;
begin
  Result := FCounterStep;
end;

function TNoiseChannel.GetDivisorRatio: Double;
begin
  Result := FDivisorRatio;
end;

function TNoiseChannel.GetShiftFrequency: Integer;
begin
  Result := FShiftFrequency;
end;

function TNoiseChannel.GetVolume: TEnvelope;
begin
  Result := FVolume;
end;

procedure TNoiseChannel.SetCounterStep(Value: Integer);
begin
  FCounterStep := Value;
end;

procedure TNoiseChannel.SetDivisorRatio(Value: Double);
begin
  FDivisorRatio := Value;
end;

procedure TNoiseChannel.SetShiftFrequency(Value: Integer);
begin
  FShiftFrequency := Value;
end;

procedure TNoiseChannel.SetVolume(Value: TEnvelope);
begin
  if FVolume <> Value then
    FVolume.Free;

  FVolume := Value;
end;

end.

