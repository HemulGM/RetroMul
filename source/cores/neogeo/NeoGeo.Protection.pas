unit NeoGeo.Protection;

interface

uses
  System.SysUtils, System.Classes;

procedure DecryptCMC(var Graphics, Fixed, Audio: TBytes; Key: Byte; CMC50, ExtractFixed, EncryptedAudio: Boolean);

procedure ExtractCMCText(const Graphics: TBytes; var Fixed: TBytes);

procedure DecryptCMCAudio(var Audio: TBytes);

procedure DecryptKOF98(var ProgramData: TBytes);

procedure DecryptPCM(var Samples: TBytes; BlockSize, Variant: Integer);

procedure ReorderProgram(var ProgramData: TBytes; const Kind: string);

procedure DecryptSMA(var ProgramData: TBytes; const Kind: string);

function SMABank(const Kind: string; Value: Word): Integer;

procedure DecryptPVC(var ProgramData: TBytes; const Kind: string);

implementation

// Adapted from MAME, BSD-3-Clause. Copyright S. Smith, David Haywood,
// Fabio Priuli and the contributors listed in LICENSE.txt.

type
  TTable = array[0..255] of Byte;

  TXorTable = array[0..31] of Byte;

const
  kof99_type0_t03: TTable = (
    $fb, $86, $9d, $f1, $bf, $80, $d5, $43, $ab, $b3, $9f, $6a, $33, $d9, $db, $b6,
    $66, $08, $69, $88, $cc, $b7, $de, $49, $97, $64, $1f, $a6, $c0, $2f, $52, $42,
    $44, $5a, $f2, $28, $98, $87, $96, $8a, $83, $0b, $03, $61, $71, $99, $6b, $b5,
    $1a, $8e, $fe, $04, $e1, $f7, $7d, $dd, $ed, $ca, $37, $fc, $ef, $39, $72, $da,
    $b8, $be, $ee, $7f, $e5, $31, $78, $f3, $91, $9a, $d2, $11, $19, $b9, $09, $4c,
    $fd, $6d, $2a, $4d, $65, $a1, $89, $c7, $75, $50, $21, $fa, $16, $00, $e9, $12,
    $74, $2b, $1e, $4f, $14, $01, $70, $3a, $4e, $3f, $f5, $f4, $1d, $3d, $15, $27,
    $a7, $ff, $45, $e0, $6e, $f9, $54, $c8, $48, $ad, $a5, $0a, $f6, $2d, $2c, $e2,
    $68, $67, $d6, $85, $b4, $c3, $34, $bc, $62, $d3, $5f, $84, $06, $5b, $0d, $95,
    $ea, $5e, $9e, $d4, $eb, $90, $7a, $05, $81, $57, $e8, $60, $2e, $20, $25, $7c,
    $46, $0c, $93, $cb, $bd, $17, $7e, $ec, $79, $b2, $c2, $22, $41, $b1, $10, $ac,
    $a8, $bb, $9b, $82, $4b, $9c, $8b, $07, $47, $35, $24, $56, $8d, $af, $e6, $26,
    $40, $38, $c4, $5d, $1b, $c5, $d1, $0f, $6c, $7b, $b0, $e3, $a3, $23, $6f, $58,
    $c1, $ba, $cf, $d7, $a2, $e7, $d0, $63, $5c, $f8, $73, $a0, $13, $dc, $29, $cd,
    $c9, $76, $ae, $8f, $e4, $59, $30, $aa, $94, $1c, $3c, $0e, $55, $92, $77, $32,
    $c6, $ce, $18, $36, $df, $a9, $8c, $d8, $a4, $f0, $3b, $51, $4a, $02, $3e, $53);
  kof99_type0_t12: TTable = (
    $1f, $ac, $4d, $cd, $ca, $70, $02, $6b, $18, $40, $62, $b2, $3f, $9b, $5b, $ef,
    $69, $68, $71, $3b, $cb, $d4, $30, $bc, $47, $72, $74, $5e, $84, $4c, $1b, $db,
    $6a, $35, $1d, $f5, $a1, $b3, $87, $5d, $57, $28, $2f, $c4, $fd, $24, $26, $36,
    $ad, $be, $61, $63, $73, $aa, $82, $ee, $29, $d0, $df, $8c, $15, $b5, $96, $f3,
    $dd, $7e, $3a, $37, $58, $7f, $0c, $fc, $0b, $07, $e8, $f7, $f4, $14, $b8, $81,
    $b6, $d7, $1e, $c8, $85, $e6, $9d, $33, $60, $c5, $95, $d5, $55, $00, $a3, $b7,
    $7d, $50, $0d, $d2, $c1, $12, $e5, $ed, $d8, $a4, $9c, $8f, $2a, $4f, $a8, $01,
    $52, $83, $65, $ea, $9a, $6c, $44, $4a, $e2, $a5, $2b, $46, $e1, $34, $25, $f8,
    $c3, $da, $c7, $6e, $48, $38, $7c, $78, $06, $53, $64, $16, $98, $3c, $91, $42,
    $39, $cc, $b0, $f1, $eb, $13, $bb, $05, $32, $86, $0e, $a2, $0a, $9e, $fa, $66,
    $54, $8e, $d3, $e7, $19, $20, $77, $ec, $ff, $bd, $6d, $43, $23, $03, $ab, $75,
    $3d, $cf, $d1, $de, $92, $31, $a7, $45, $4b, $c2, $97, $f9, $7a, $88, $d9, $1c,
    $e9, $e4, $10, $c9, $22, $2d, $90, $76, $17, $79, $04, $51, $1a, $5a, $5f, $2c,
    $21, $6f, $3e, $e0, $f0, $bf, $d6, $94, $0f, $80, $11, $a0, $5c, $a9, $49, $2e,
    $ce, $af, $a6, $9f, $7b, $99, $b9, $b4, $e3, $fb, $f6, $27, $f2, $93, $fe, $08,
    $67, $ae, $09, $89, $dc, $4e, $c6, $c0, $8a, $b1, $59, $8b, $41, $56, $8d, $ba);
  kof99_type1_t03: TTable = (
    $a9, $17, $af, $0d, $34, $6e, $53, $b6, $7f, $58, $e9, $14, $5f, $55, $db, $d4,
    $42, $80, $99, $59, $a8, $3a, $57, $5d, $d5, $6f, $4c, $68, $35, $46, $a6, $e7,
    $7b, $71, $e0, $93, $a2, $1f, $64, $21, $e3, $b1, $98, $26, $ab, $ad, $ee, $e5,
    $bb, $d9, $1e, $2e, $95, $36, $ef, $23, $79, $45, $04, $ed, $13, $1d, $f4, $85,
    $96, $ec, $c2, $32, $aa, $7c, $15, $d8, $da, $92, $90, $9d, $b7, $56, $6a, $66,
    $41, $fc, $00, $f6, $50, $24, $cf, $fb, $11, $fe, $82, $48, $9b, $27, $1b, $67,
    $4e, $84, $69, $97, $6d, $8c, $d2, $ba, $74, $f9, $8f, $a5, $54, $5c, $cd, $73,
    $07, $d1, $01, $09, $f1, $19, $3b, $5e, $87, $30, $76, $cc, $c0, $5a, $a7, $49,
    $22, $fa, $16, $02, $df, $a4, $ff, $b3, $75, $33, $bd, $88, $2f, $cb, $2a, $44,
    $b8, $bf, $1c, $0f, $81, $10, $43, $b4, $c8, $7e, $9a, $25, $ea, $83, $4b, $38,
    $7a, $d7, $3d, $1a, $4f, $62, $51, $c9, $47, $0e, $ce, $3f, $c7, $4d, $2c, $a1,
    $86, $b9, $c5, $ca, $dd, $6b, $70, $6c, $91, $9c, $be, $0a, $9f, $f5, $94, $bc,
    $18, $2b, $60, $20, $29, $f7, $f2, $28, $c4, $a0, $0b, $65, $de, $8d, $78, $12,
    $3e, $d0, $77, $08, $8b, $ae, $05, $31, $3c, $d6, $a3, $89, $06, $dc, $52, $72,
    $b0, $b5, $37, $d3, $c3, $8a, $c6, $f0, $c1, $61, $fd, $4a, $5b, $7d, $9e, $f3,
    $63, $40, $2d, $e8, $b2, $e6, $39, $03, $eb, $8e, $e1, $0c, $e4, $e2, $f8, $ac);
  kof99_type1_t12: TTable = (
    $ea, $e6, $5e, $a7, $8e, $ac, $34, $03, $30, $97, $52, $53, $76, $f2, $62, $0b,
    $0a, $fc, $94, $b8, $67, $36, $11, $bc, $ae, $ca, $fa, $15, $04, $2b, $17, $c4,
    $3e, $5b, $59, $01, $57, $e2, $ba, $b7, $d1, $3f, $f0, $6a, $9c, $2a, $cb, $a9,
    $e3, $2c, $c0, $0f, $46, $91, $8a, $d0, $98, $c5, $a6, $1b, $96, $29, $12, $09,
    $63, $ed, $e0, $a2, $86, $77, $be, $e5, $65, $db, $bd, $50, $b3, $9d, $1a, $4e,
    $79, $0c, $00, $43, $df, $3d, $54, $33, $8f, $89, $a8, $7b, $f9, $d5, $27, $82,
    $bb, $c2, $8c, $47, $88, $6b, $b4, $c3, $f8, $aa, $06, $1e, $83, $7d, $05, $78,
    $85, $f6, $6e, $2e, $ec, $5a, $31, $45, $38, $14, $16, $8b, $02, $e4, $4f, $b0,
    $bf, $ab, $a4, $9e, $48, $60, $19, $35, $08, $de, $dd, $66, $90, $51, $cc, $a3,
    $af, $70, $9b, $75, $95, $49, $6c, $64, $72, $7e, $44, $a0, $73, $25, $68, $55,
    $1f, $40, $7a, $74, $0e, $8d, $dc, $1c, $71, $c8, $cf, $d7, $e8, $ce, $eb, $32,
    $3a, $ee, $07, $61, $4d, $fe, $5c, $7c, $56, $2f, $2d, $5f, $6f, $9f, $81, $22,
    $58, $4b, $ad, $da, $b9, $10, $18, $23, $e1, $f3, $6d, $e7, $e9, $28, $d6, $d8,
    $f4, $4c, $39, $21, $b2, $84, $c1, $24, $26, $f1, $93, $37, $c6, $4a, $cd, $20,
    $c9, $d9, $c7, $b1, $ff, $99, $d4, $5d, $b5, $a1, $87, $0d, $69, $92, $13, $80,
    $d2, $d3, $fd, $1d, $f5, $3b, $a5, $7f, $ef, $9a, $b6, $42, $fb, $3c, $f7, $41);
  kof99_address_8_15_xor1: TTable = (
    $00, $b1, $1e, $c5, $3d, $40, $45, $5e, $f2, $f8, $04, $63, $36, $87, $88, $bf,
    $ab, $cc, $78, $08, $dd, $20, $d4, $35, $09, $8e, $44, $ae, $33, $a9, $9e, $cd,
    $b3, $e5, $ad, $41, $da, $be, $f4, $16, $57, $2e, $53, $67, $af, $db, $8a, $d8,
    $34, $17, $3c, $01, $55, $73, $cf, $e3, $e8, $c7, $0d, $e9, $a3, $13, $0c, $f6,
    $90, $4e, $fb, $97, $6d, $5f, $a8, $71, $11, $fc, $d1, $95, $81, $ba, $8c, $1b,
    $39, $fe, $a2, $15, $a6, $52, $4d, $5b, $59, $a5, $e0, $96, $d9, $8f, $7b, $ed,
    $29, $d3, $1f, $0e, $ec, $23, $0f, $b8, $6c, $6f, $7d, $18, $46, $d6, $e4, $b5,
    $9a, $79, $02, $f5, $03, $c0, $60, $66, $5c, $2f, $76, $85, $9d, $54, $1a, $6a,
    $28, $ce, $7f, $7c, $91, $99, $4c, $83, $3e, $b4, $1d, $05, $c1, $c3, $d7, $47,
    $de, $bc, $62, $6e, $86, $14, $80, $77, $eb, $f3, $07, $31, $56, $d2, $c2, $c6,
    $6b, $dc, $fd, $22, $92, $f0, $06, $51, $2d, $38, $e6, $a0, $25, $df, $d5, $2c,
    $1c, $94, $12, $9c, $b0, $9b, $c4, $0b, $c8, $d0, $f7, $30, $cb, $27, $fa, $7a,
    $10, $61, $aa, $a4, $70, $b7, $2a, $5a, $c9, $f1, $0a, $49, $65, $ee, $69, $4b,
    $3a, $8d, $32, $5d, $68, $b9, $9f, $75, $19, $3f, $ac, $37, $4f, $e7, $93, $89,
    $7e, $4a, $3b, $ea, $74, $72, $43, $bd, $24, $ef, $b6, $ff, $64, $58, $84, $8b,
    $a7, $bb, $b2, $e1, $26, $2b, $50, $ca, $21, $f9, $98, $a1, $e2, $42, $82, $48);
  kof99_address_8_15_xor2: TTable = (
    $9b, $9d, $c1, $3d, $a9, $b8, $f4, $6f, $f6, $25, $c7, $47, $d5, $97, $df, $6b,
    $eb, $90, $a4, $b2, $5d, $f5, $66, $b0, $b9, $8b, $93, $64, $ec, $7b, $65, $8c,
    $f1, $43, $42, $6e, $45, $9f, $b3, $35, $06, $71, $96, $db, $a0, $fb, $0b, $3a,
    $1f, $f8, $8e, $69, $cd, $26, $ab, $86, $a2, $0c, $bd, $63, $a5, $7a, $e7, $6a,
    $5f, $18, $9e, $bf, $ad, $55, $b1, $1c, $5c, $03, $30, $c6, $37, $20, $e3, $c9,
    $52, $e8, $ee, $4f, $01, $70, $c4, $77, $29, $2a, $ba, $53, $12, $04, $7d, $af,
    $33, $8f, $a8, $4d, $aa, $5b, $b4, $0f, $92, $bb, $ed, $e1, $2f, $50, $6c, $d2,
    $2c, $95, $d9, $f9, $98, $c3, $76, $4c, $f2, $e4, $e5, $2b, $ef, $9c, $49, $b6,
    $31, $3b, $bc, $a1, $ca, $de, $62, $74, $ea, $81, $00, $dd, $a6, $46, $88, $3f,
    $39, $d6, $23, $54, $24, $4a, $d8, $dc, $d7, $d1, $cc, $be, $57, $7c, $da, $44,
    $61, $ce, $d3, $d4, $e9, $28, $80, $e0, $56, $8a, $09, $05, $9a, $89, $1b, $f7,
    $f3, $99, $6d, $5e, $48, $91, $c0, $d0, $c5, $79, $78, $41, $59, $21, $2e, $ff,
    $c2, $4b, $38, $83, $32, $e6, $e2, $7f, $1e, $17, $58, $1d, $1a, $fa, $85, $82,
    $94, $c8, $72, $7e, $b7, $ac, $0e, $fc, $fd, $16, $27, $75, $8d, $cb, $08, $fe,
    $0a, $02, $0d, $36, $11, $22, $84, $40, $34, $3e, $2d, $68, $5a, $a7, $67, $ae,
    $87, $07, $10, $60, $14, $73, $3c, $51, $19, $a3, $b5, $cf, $13, $f0, $15, $4e);
  kof99_address_16_23_xor1: TTable = (
    $00, $5f, $03, $52, $ce, $e3, $7d, $8f, $6b, $f8, $20, $de, $7b, $7e, $39, $be,
    $f5, $94, $18, $78, $80, $c9, $7f, $7a, $3e, $63, $f2, $e0, $4e, $f7, $87, $27,
    $69, $6c, $a4, $1d, $85, $5b, $e6, $44, $25, $0c, $98, $c7, $01, $02, $a3, $26,
    $09, $38, $db, $c3, $1e, $cf, $23, $45, $68, $76, $d6, $22, $5d, $5a, $ae, $16,
    $9f, $a2, $b5, $cd, $81, $ea, $5e, $b8, $b9, $9d, $9c, $1a, $0f, $ff, $e1, $e7,
    $74, $aa, $d4, $af, $fc, $c6, $33, $29, $5c, $ab, $95, $f0, $19, $47, $59, $67,
    $f3, $96, $60, $1f, $62, $92, $bd, $89, $ee, $28, $13, $06, $fe, $fa, $32, $6d,
    $57, $3c, $54, $50, $2c, $58, $49, $fb, $17, $cc, $ef, $b2, $b4, $f9, $07, $70,
    $c5, $a9, $df, $d5, $3b, $86, $2b, $0d, $6e, $4d, $0a, $90, $43, $31, $c1, $f6,
    $88, $0b, $da, $53, $14, $dc, $75, $8e, $b0, $eb, $99, $46, $a1, $15, $71, $c8,
    $e9, $3f, $4a, $d9, $73, $e5, $7c, $30, $77, $d3, $b3, $4b, $37, $72, $c2, $04,
    $97, $08, $36, $b1, $3a, $61, $ec, $e2, $1c, $9a, $8b, $d1, $1b, $2e, $9e, $8a,
    $d8, $41, $e4, $c4, $40, $2f, $ad, $c0, $b6, $84, $51, $66, $bb, $12, $e8, $dd,
    $cb, $bc, $6f, $d0, $11, $83, $56, $4c, $ca, $bf, $05, $10, $d7, $ba, $fd, $ed,
    $8c, $0e, $4f, $3d, $35, $91, $b7, $ac, $34, $64, $2a, $f1, $79, $6a, $9b, $2d,
    $65, $f4, $42, $a0, $8d, $a7, $48, $55, $21, $93, $24, $d2, $a6, $a5, $a8, $82);
  kof99_address_16_23_xor2: TTable = (
    $29, $97, $1a, $2c, $0b, $94, $3e, $75, $01, $0d, $1b, $e1, $4d, $38, $39, $8f,
    $e7, $d0, $60, $90, $b2, $0f, $bb, $70, $1f, $e6, $5b, $87, $b4, $43, $fd, $f5,
    $f6, $f9, $ad, $c0, $98, $17, $9f, $91, $15, $51, $55, $64, $6c, $18, $61, $0e,
    $d9, $93, $ab, $d6, $24, $2f, $6a, $3a, $22, $b1, $4f, $aa, $23, $48, $ed, $b9,
    $88, $8b, $a3, $6b, $26, $4c, $e8, $2d, $1c, $99, $bd, $5c, $58, $08, $50, $f2,
    $2a, $62, $c1, $72, $66, $04, $10, $37, $6e, $fc, $44, $a9, $df, $d4, $20, $dd,
    $ee, $41, $db, $73, $de, $54, $ec, $c9, $f3, $4b, $2e, $ae, $5a, $4a, $5e, $47,
    $07, $2b, $76, $a4, $e3, $28, $fe, $b0, $f0, $02, $06, $d1, $af, $42, $c2, $a5,
    $e0, $67, $bf, $16, $8e, $35, $ce, $8a, $e5, $3d, $7b, $96, $d7, $79, $52, $1e,
    $a1, $fb, $9b, $be, $21, $9c, $e9, $56, $14, $7f, $a0, $e4, $c3, $c4, $46, $ea,
    $f7, $d2, $1d, $31, $0a, $5f, $eb, $a2, $68, $8d, $b5, $c5, $74, $0c, $dc, $82,
    $80, $09, $19, $95, $71, $9a, $11, $57, $77, $4e, $c6, $ff, $12, $03, $a7, $c7,
    $f4, $c8, $b6, $7a, $59, $36, $3c, $53, $e2, $69, $8c, $25, $05, $45, $63, $f8,
    $34, $89, $33, $3f, $85, $27, $bc, $65, $fa, $a8, $6d, $84, $5d, $ba, $40, $32,
    $30, $ef, $83, $13, $a6, $78, $cc, $81, $9e, $da, $ca, $d3, $7e, $9d, $6f, $cd,
    $b7, $b3, $d8, $cf, $3b, $00, $92, $b8, $86, $ac, $49, $7c, $f1, $d5, $cb, $7d);
  kof99_address_0_7_xor: TTable = (
    $74, $ad, $5d, $1d, $9e, $c3, $fa, $4e, $f7, $db, $ca, $a2, $64, $36, $56, $0c,
    $4f, $cf, $43, $66, $1e, $91, $e3, $a5, $58, $c2, $c1, $d4, $b9, $dd, $76, $16,
    $ce, $61, $75, $01, $2b, $22, $38, $55, $50, $ef, $6c, $99, $05, $e9, $e8, $e0,
    $2d, $a4, $4b, $4a, $42, $ae, $ba, $8c, $6f, $93, $14, $bd, $71, $21, $b0, $02,
    $15, $c4, $e6, $60, $d7, $44, $fd, $85, $7e, $78, $8f, $00, $81, $f1, $a7, $3b,
    $a0, $10, $f4, $9f, $39, $88, $35, $62, $cb, $19, $31, $11, $51, $fb, $2a, $20,
    $45, $d3, $7d, $92, $1b, $f2, $09, $0d, $97, $a9, $b5, $3c, $ee, $5c, $af, $7b,
    $d2, $3a, $49, $8e, $b6, $cd, $d9, $de, $8a, $29, $6e, $d8, $0b, $e1, $69, $87,
    $1a, $96, $18, $cc, $df, $e7, $c5, $c7, $f8, $52, $c9, $f0, $b7, $e5, $33, $da,
    $67, $9d, $a3, $03, $0e, $72, $26, $79, $e2, $b8, $fc, $aa, $fe, $b4, $86, $c8,
    $d1, $bc, $12, $08, $77, $eb, $40, $8d, $04, $25, $4d, $5a, $6a, $7a, $2e, $41,
    $65, $1c, $13, $94, $b2, $63, $28, $59, $5e, $9a, $30, $07, $c6, $bf, $17, $f5,
    $0f, $89, $f3, $1f, $ea, $6d, $b3, $c0, $70, $47, $f9, $53, $f6, $d6, $54, $ed,
    $6b, $4c, $e4, $8b, $83, $24, $90, $b1, $7c, $bb, $73, $ab, $d5, $2f, $5f, $ec,
    $9c, $2c, $a8, $34, $46, $37, $27, $a1, $0a, $06, $80, $68, $82, $32, $84, $ff,
    $48, $ac, $7f, $3f, $95, $dc, $98, $9b, $be, $23, $57, $3e, $5b, $d0, $3d, $a6);
  kof2000_type0_t03: TTable = (
    $10, $61, $f1, $78, $85, $52, $68, $e3, $12, $0d, $fa, $f0, $c9, $36, $5e, $3d,
    $f9, $a6, $01, $2e, $c7, $84, $ea, $2b, $6d, $14, $38, $4f, $55, $1c, $9d, $a7,
    $7a, $c6, $f8, $9a, $e6, $42, $b5, $ed, $7d, $3a, $b1, $05, $43, $4a, $22, $fd,
    $ac, $a4, $31, $c3, $32, $76, $95, $9e, $7e, $88, $8e, $a2, $97, $18, $be, $2a,
    $f5, $d6, $ca, $cc, $72, $3b, $87, $6c, $de, $75, $d7, $21, $cb, $0b, $dd, $e7,
    $e1, $65, $aa, $b9, $44, $fb, $66, $15, $1a, $3c, $98, $cf, $8a, $df, $37, $a5,
    $2f, $67, $d2, $83, $b6, $6b, $fc, $e0, $b4, $7c, $08, $dc, $93, $30, $ab, $e4,
    $19, $c2, $8b, $eb, $a0, $0a, $c8, $03, $c0, $4b, $64, $71, $86, $9c, $9b, $16,
    $79, $ff, $70, $09, $8c, $d0, $f6, $53, $07, $73, $d4, $89, $b3, $00, $e9, $fe,
    $ec, $8f, $bc, $b2, $1e, $5d, $11, $35, $a9, $06, $59, $9f, $c1, $d3, $7b, $f2,
    $c5, $77, $4e, $39, $20, $d5, $6a, $82, $da, $45, $f3, $33, $81, $23, $ba, $e2,
    $1d, $5f, $5c, $51, $49, $ae, $8d, $c4, $a8, $f7, $1f, $0f, $34, $28, $a1, $d9,
    $27, $d8, $4c, $2c, $bf, $91, $3e, $69, $57, $41, $25, $0c, $5a, $90, $92, $b0,
    $63, $6f, $40, $af, $74, $b8, $2d, $80, $bb, $46, $94, $e5, $29, $ee, $b7, $1b,
    $96, $ad, $13, $0e, $58, $99, $60, $4d, $17, $26, $ce, $e8, $db, $ef, $24, $a3,
    $6e, $7f, $54, $3f, $02, $d1, $5b, $50, $56, $48, $f4, $bd, $62, $47, $04, $cd);
  kof2000_type0_t12: TTable = (
    $f4, $28, $b4, $8f, $fa, $eb, $8e, $54, $2b, $49, $d1, $76, $71, $47, $8b, $57,
    $92, $85, $7c, $b8, $5c, $22, $f9, $26, $bc, $5b, $6d, $67, $ae, $5f, $6f, $f5,
    $9f, $48, $66, $40, $0d, $11, $4e, $b2, $6b, $35, $15, $0f, $18, $25, $1d, $ba,
    $d3, $69, $79, $ec, $a8, $8c, $c9, $7f, $4b, $db, $51, $af, $ca, $e2, $b3, $81,
    $12, $5e, $7e, $38, $c8, $95, $01, $ff, $fd, $fb, $f2, $74, $62, $14, $a5, $98,
    $a6, $da, $80, $53, $e8, $56, $ac, $1b, $52, $d0, $f1, $45, $42, $b6, $1a, $4a,
    $3a, $99, $fc, $d2, $9c, $cf, $31, $2d, $dd, $86, $2f, $29, $e1, $03, $19, $a2,
    $41, $33, $83, $90, $c1, $bf, $0b, $08, $3d, $d8, $8d, $6c, $39, $a0, $e3, $55,
    $02, $50, $46, $e6, $c3, $82, $36, $13, $75, $ab, $27, $d7, $1f, $0a, $d4, $89,
    $59, $4f, $c0, $5d, $c6, $f7, $88, $bd, $3c, $00, $ef, $cd, $05, $1c, $aa, $9b,
    $ed, $7a, $61, $17, $93, $fe, $23, $b9, $f3, $68, $78, $f6, $5a, $7b, $e0, $e4,
    $a3, $ee, $16, $72, $c7, $3b, $8a, $37, $2a, $70, $a9, $2c, $21, $f8, $24, $09,
    $ce, $20, $9e, $06, $87, $c5, $04, $64, $43, $7d, $4d, $10, $d6, $a4, $94, $4c,
    $60, $de, $df, $58, $b1, $44, $3f, $b0, $d9, $e5, $cb, $bb, $be, $ea, $07, $34,
    $73, $6a, $77, $f0, $9d, $0c, $2e, $0e, $91, $9a, $cc, $c2, $b7, $63, $97, $d5,
    $dc, $c4, $32, $e7, $84, $3e, $30, $a1, $1e, $b5, $6e, $65, $e9, $ad, $a7, $96);
  kof2000_type1_t03: TTable = (
    $9a, $2f, $cc, $4e, $40, $69, $ac, $ca, $a5, $7b, $0a, $61, $91, $0d, $55, $74,
    $cd, $8b, $0b, $80, $09, $5e, $38, $c7, $da, $bf, $f5, $37, $23, $31, $33, $e9,
    $ae, $87, $e5, $fa, $6e, $5c, $ad, $f4, $76, $62, $9f, $2e, $01, $e2, $f6, $47,
    $8c, $7c, $aa, $98, $b5, $92, $51, $ec, $5f, $07, $5d, $6f, $16, $a1, $1d, $a9,
    $48, $45, $f0, $6a, $9c, $1e, $11, $a0, $06, $46, $d5, $f1, $73, $ed, $94, $f7,
    $c3, $57, $1b, $e0, $97, $b1, $a4, $a7, $24, $e7, $2b, $05, $5b, $34, $0c, $b8,
    $0f, $9b, $c8, $4d, $5a, $a6, $86, $3e, $14, $29, $84, $58, $90, $db, $2d, $54,
    $9d, $82, $d4, $7d, $c6, $67, $41, $89, $c1, $13, $b0, $9e, $81, $6d, $a8, $59,
    $bd, $39, $8e, $e6, $25, $8f, $d9, $a2, $e4, $53, $c5, $72, $7e, $36, $4a, $4f,
    $52, $c2, $22, $2a, $ce, $3c, $21, $2c, $00, $d7, $75, $8a, $27, $ee, $43, $fe,
    $cb, $6b, $b9, $a3, $78, $b7, $85, $02, $20, $d0, $83, $c4, $12, $f9, $fd, $d8,
    $79, $64, $3a, $49, $03, $b4, $c0, $f2, $df, $15, $93, $08, $35, $ff, $70, $dd,
    $28, $6c, $0e, $04, $de, $7a, $65, $d2, $ab, $42, $95, $e1, $3f, $3b, $7f, $66,
    $d1, $8d, $e3, $bb, $1c, $fc, $77, $1a, $88, $18, $19, $68, $1f, $56, $d6, $e8,
    $b6, $bc, $d3, $ea, $3d, $26, $b3, $c9, $44, $dc, $f3, $32, $30, $ef, $96, $4c,
    $af, $17, $f8, $fb, $60, $50, $eb, $4b, $99, $63, $ba, $b2, $71, $cf, $10, $be);
  kof2000_type1_t12: TTable = (
    $da, $a7, $d6, $6e, $2f, $5e, $f0, $3f, $a4, $ce, $d3, $fd, $46, $2a, $ac, $c9,
    $be, $eb, $9f, $d5, $3c, $61, $96, $11, $d0, $38, $ca, $06, $ed, $1b, $65, $e7,
    $23, $dd, $d9, $05, $bf, $5b, $5d, $a5, $95, $00, $ec, $f1, $01, $a9, $a6, $fc,
    $bb, $54, $e3, $2e, $92, $58, $0a, $7b, $b6, $cc, $b1, $5f, $14, $35, $72, $ff,
    $e6, $52, $d7, $8c, $f3, $43, $af, $9c, $c0, $4f, $0c, $42, $8e, $ef, $80, $cd,
    $1d, $7e, $88, $3b, $98, $a1, $ad, $e4, $9d, $8d, $2b, $56, $b5, $50, $df, $66,
    $6d, $d4, $60, $09, $e1, $ee, $4a, $47, $f9, $fe, $73, $07, $89, $a8, $39, $ea,
    $82, $9e, $cf, $26, $b2, $4e, $c3, $59, $f2, $3d, $9a, $b0, $69, $f7, $bc, $34,
    $e5, $36, $22, $fb, $57, $71, $99, $6c, $83, $30, $55, $c2, $bd, $f4, $77, $e9,
    $76, $97, $a0, $e0, $b9, $86, $6b, $a3, $84, $67, $1a, $70, $02, $5a, $41, $5c,
    $25, $81, $aa, $28, $78, $4b, $c6, $64, $53, $16, $4d, $8b, $20, $93, $ae, $0f,
    $94, $2c, $3a, $c7, $62, $e8, $c4, $db, $04, $c5, $fa, $29, $48, $d1, $08, $24,
    $0d, $e2, $d8, $10, $b4, $91, $8a, $13, $0e, $dc, $d2, $79, $b8, $f8, $ba, $2d,
    $cb, $f5, $7d, $37, $51, $40, $31, $a2, $0b, $18, $63, $7f, $b3, $ab, $9b, $87,
    $f6, $90, $de, $c8, $27, $45, $7c, $1c, $85, $68, $33, $19, $03, $75, $15, $7a,
    $1f, $49, $8f, $4c, $c1, $44, $17, $12, $6f, $32, $b7, $3e, $74, $1e, $21, $6a);
  kof2000_address_8_15_xor1: TTable = (
    $fc, $9b, $1c, $35, $72, $53, $d6, $7d, $84, $a4, $c5, $93, $7b, $e7, $47, $d5,
    $24, $a2, $fa, $19, $0c, $b1, $8c, $b9, $9d, $d8, $59, $4f, $3c, $b2, $78, $4a,
    $2a, $96, $9a, $f1, $1f, $22, $a8, $5b, $67, $a3, $0f, $00, $fb, $df, $eb, $0a,
    $57, $b8, $25, $d7, $f0, $6b, $0b, $31, $95, $23, $2d, $5c, $27, $c7, $f4, $55,
    $1a, $f7, $74, $be, $d3, $ac, $3d, $c1, $7f, $bd, $28, $01, $10, $e5, $09, $37,
    $1e, $58, $af, $17, $f2, $16, $30, $92, $36, $68, $e6, $d4, $ea, $b7, $75, $54,
    $77, $41, $b4, $8d, $e0, $f3, $51, $03, $a9, $e8, $66, $ab, $29, $a5, $ed, $cb,
    $d1, $aa, $f5, $db, $4c, $42, $97, $8a, $ae, $c9, $6e, $04, $33, $85, $dd, $2b,
    $6f, $ef, $12, $21, $7a, $a1, $5a, $91, $c8, $cc, $c0, $a7, $60, $3e, $56, $2f,
    $e4, $71, $99, $c2, $a0, $45, $80, $65, $bb, $87, $69, $81, $73, $ca, $f6, $46,
    $43, $da, $26, $7e, $8f, $e1, $8b, $fd, $50, $79, $ba, $c6, $63, $4b, $b3, $8e,
    $34, $e2, $48, $14, $cd, $e3, $c4, $05, $13, $40, $06, $6c, $88, $b0, $e9, $1b,
    $4d, $f8, $76, $02, $44, $94, $cf, $32, $fe, $ce, $3b, $5d, $2c, $89, $5f, $dc,
    $d2, $9c, $6a, $ec, $18, $6d, $0e, $86, $ff, $5e, $9e, $ee, $11, $d0, $49, $52,
    $4e, $61, $90, $0d, $c3, $39, $15, $83, $b5, $62, $3f, $70, $7c, $ad, $20, $bf,
    $2e, $08, $1d, $f9, $b6, $a6, $64, $07, $82, $38, $98, $3a, $9f, $de, $bc, $d9);
  kof2000_address_8_15_xor2: TTable = (
    $00, $be, $06, $5a, $fa, $42, $15, $f2, $3f, $0a, $84, $93, $4e, $78, $3b, $89,
    $32, $98, $a2, $87, $73, $dd, $26, $e5, $05, $71, $08, $6e, $9b, $e0, $df, $9e,
    $fc, $83, $81, $ef, $b2, $c0, $c3, $bf, $a7, $6d, $1b, $95, $ed, $b9, $3e, $13,
    $b0, $47, $9c, $7a, $24, $41, $68, $d0, $36, $0b, $b5, $c2, $67, $f7, $54, $92,
    $1e, $44, $86, $2b, $94, $cc, $ba, $23, $0d, $ca, $6b, $4c, $2a, $9a, $2d, $8b,
    $e3, $52, $29, $f0, $21, $bd, $bb, $1f, $a3, $ab, $f8, $46, $b7, $45, $82, $5e,
    $db, $07, $5d, $e9, $9d, $1a, $48, $ce, $91, $12, $d4, $ee, $a9, $39, $f1, $18,
    $2c, $22, $8a, $7e, $34, $4a, $8c, $c1, $14, $f3, $20, $35, $d9, $96, $33, $77,
    $9f, $76, $7c, $90, $c6, $d5, $a1, $5b, $ac, $75, $c7, $0c, $b3, $17, $d6, $99,
    $56, $a6, $3d, $1d, $b1, $2e, $d8, $bc, $2f, $de, $60, $55, $6c, $40, $cd, $43,
    $ff, $ad, $38, $79, $51, $c8, $0e, $5f, $c4, $66, $cb, $a8, $7d, $a4, $3a, $ea,
    $27, $7b, $70, $8e, $5c, $19, $0f, $80, $6f, $8f, $10, $f9, $49, $85, $69, $7f,
    $eb, $1c, $01, $65, $37, $a5, $28, $e4, $6a, $03, $04, $d1, $31, $11, $30, $fb,
    $88, $97, $d3, $f6, $c5, $4d, $f5, $3c, $e8, $61, $dc, $d2, $b4, $b8, $a0, $ae,
    $16, $25, $02, $09, $fe, $cf, $53, $63, $af, $59, $f4, $e1, $ec, $d7, $e7, $50,
    $e2, $c9, $aa, $4b, $8d, $4f, $e6, $64, $da, $74, $b6, $72, $57, $62, $fd, $58);
  kof2000_address_16_23_xor1: TTable = (
    $45, $9f, $6e, $2f, $28, $bc, $5e, $6d, $da, $b5, $0d, $b8, $c0, $8e, $a2, $32,
    $ee, $cd, $8d, $48, $8c, $27, $14, $eb, $65, $d7, $f2, $93, $99, $90, $91, $fc,
    $5f, $cb, $fa, $75, $3f, $26, $de, $72, $33, $39, $c7, $1f, $88, $79, $73, $ab,
    $4e, $36, $5d, $44, $d2, $41, $a0, $7e, $a7, $8b, $a6, $bf, $03, $d8, $86, $dc,
    $2c, $aa, $70, $3d, $46, $07, $80, $58, $0b, $2b, $e2, $f0, $b1, $fe, $42, $f3,
    $e9, $a3, $85, $78, $c3, $d0, $5a, $db, $1a, $fb, $9d, $8a, $a5, $12, $0e, $54,
    $8f, $c5, $6c, $ae, $25, $5b, $4b, $17, $02, $9c, $4a, $24, $40, $e5, $9e, $22,
    $c6, $49, $62, $b6, $6b, $bb, $a8, $cc, $e8, $81, $50, $47, $c8, $be, $5c, $a4,
    $d6, $94, $4f, $7b, $9a, $cf, $e4, $59, $7a, $a1, $ea, $31, $37, $13, $2d, $af,
    $21, $69, $19, $1d, $6f, $16, $98, $1e, $08, $e3, $b2, $4d, $9b, $7f, $a9, $77,
    $ed, $bd, $d4, $d9, $34, $d3, $ca, $09, $18, $60, $c9, $6a, $01, $f4, $f6, $64,
    $b4, $3a, $15, $ac, $89, $52, $68, $71, $e7, $82, $c1, $0c, $92, $f7, $30, $e6,
    $1c, $3e, $0f, $0a, $67, $35, $ba, $61, $dd, $29, $c2, $f8, $97, $95, $b7, $3b,
    $e0, $ce, $f9, $d5, $06, $76, $b3, $05, $4c, $04, $84, $3c, $87, $23, $63, $7c,
    $53, $56, $e1, $7d, $96, $1b, $d1, $ec, $2a, $66, $f1, $11, $10, $ff, $43, $2e,
    $df, $83, $74, $f5, $38, $20, $fd, $ad, $c4, $b9, $55, $51, $b0, $ef, $00, $57);
  kof2000_address_16_23_xor2: TTable = (
    $00, $b8, $f0, $34, $ca, $21, $3c, $f9, $01, $8e, $75, $70, $ec, $13, $27, $96,
    $f4, $5b, $88, $1f, $eb, $4a, $7d, $9d, $be, $02, $14, $af, $a2, $06, $c6, $db,
    $35, $6b, $74, $45, $7b, $29, $d2, $fe, $b6, $15, $d0, $8a, $a9, $2d, $19, $f6,
    $5e, $5a, $90, $e9, $11, $33, $c2, $47, $37, $4c, $4f, $59, $c3, $04, $57, $1d,
    $f2, $63, $6d, $6e, $31, $95, $cb, $3e, $67, $b2, $e3, $98, $ed, $8d, $e6, $fb,
    $f8, $ba, $5d, $d4, $2a, $f5, $3b, $82, $05, $16, $44, $ef, $4d, $e7, $93, $da,
    $9f, $bb, $61, $c9, $53, $bd, $76, $78, $52, $36, $0c, $66, $c1, $10, $dd, $7a,
    $84, $69, $cd, $fd, $58, $0d, $6c, $89, $68, $ad, $3a, $b0, $4b, $46, $c5, $03,
    $b4, $f7, $30, $8c, $4e, $60, $73, $a1, $8b, $b1, $62, $cc, $d1, $08, $fc, $77,
    $7e, $cf, $56, $51, $07, $a6, $80, $92, $dc, $0b, $a4, $c7, $e8, $e1, $b5, $71,
    $ea, $b3, $2f, $94, $18, $e2, $3d, $49, $65, $aa, $f1, $91, $c8, $99, $55, $79,
    $86, $a7, $26, $a0, $ac, $5f, $ce, $6a, $5c, $f3, $87, $8f, $12, $1c, $d8, $e4,
    $9b, $64, $2e, $1e, $d7, $c0, $17, $bc, $a3, $a8, $9a, $0e, $25, $40, $41, $50,
    $b9, $bf, $28, $df, $32, $54, $9e, $48, $d5, $2b, $42, $fa, $9c, $7f, $d3, $85,
    $43, $de, $81, $0f, $24, $c4, $38, $ae, $83, $1b, $6f, $7c, $e5, $ff, $1a, $d9,
    $3f, $b7, $22, $97, $09, $e0, $a5, $20, $23, $2c, $72, $d6, $39, $ab, $0a, $ee);
  kof2000_address_0_7_xor: TTable = (
    $26, $48, $06, $9b, $21, $a9, $1b, $76, $c9, $f8, $b4, $67, $e4, $ff, $99, $f7,
    $15, $9e, $62, $00, $72, $4d, $a0, $4f, $02, $f1, $ea, $ef, $0b, $f3, $eb, $a6,
    $93, $78, $6f, $7c, $da, $d4, $7b, $05, $e9, $c6, $d6, $db, $50, $ce, $d2, $01,
    $b5, $e8, $e0, $2a, $08, $1a, $b8, $e3, $f9, $b1, $f4, $8b, $39, $2d, $85, $9c,
    $55, $73, $63, $40, $38, $96, $dc, $a3, $a2, $a1, $25, $66, $6d, $56, $8e, $10,
    $0f, $31, $1c, $f5, $28, $77, $0a, $d1, $75, $34, $a4, $fe, $7d, $07, $51, $79,
    $41, $90, $22, $35, $12, $bb, $c4, $ca, $b2, $1f, $cb, $c8, $ac, $dd, $d0, $0d,
    $fc, $c5, $9d, $14, $bc, $83, $d9, $58, $c2, $30, $9a, $6a, $c0, $0c, $ad, $f6,
    $5d, $74, $7f, $2f, $bd, $1d, $47, $d5, $e6, $89, $cf, $b7, $d3, $59, $36, $98,
    $f0, $fb, $3c, $f2, $3f, $a7, $18, $82, $42, $5c, $ab, $ba, $de, $52, $09, $91,
    $aa, $61, $ec, $d7, $95, $23, $cd, $80, $a5, $68, $60, $27, $71, $e1, $2c, $2e,
    $8d, $2b, $57, $65, $bf, $c1, $19, $c7, $49, $64, $88, $4a, $cc, $20, $4e, $d8,
    $3b, $4c, $13, $5f, $9f, $be, $5e, $6e, $fd, $e2, $fa, $54, $37, $0e, $16, $7a,
    $6c, $33, $b3, $70, $84, $7e, $c3, $04, $b0, $ae, $b9, $81, $03, $29, $df, $46,
    $e5, $69, $e7, $24, $92, $5a, $4b, $5b, $94, $11, $3a, $3d, $87, $ed, $97, $b6,
    $32, $3e, $45, $af, $1e, $43, $44, $8c, $53, $86, $6b, $ee, $a8, $8a, $8f, $17);
  m1_address_8_15_xor: TTable = (
    $0a, $72, $b7, $af, $67, $de, $1d, $b1, $78, $c4, $4f, $b5, $4b, $18, $76, $dd,
    $11, $e2, $36, $a1, $82, $03, $98, $a0, $10, $5f, $3f, $d6, $1f, $90, $6a, $0b,
    $70, $e0, $64, $cb, $9f, $38, $8b, $53, $04, $ca, $f8, $d0, $07, $68, $56, $32,
    $ae, $1c, $2e, $48, $63, $92, $9a, $9c, $44, $85, $41, $40, $09, $c0, $c8, $bf,
    $ea, $bb, $f7, $2d, $99, $21, $f6, $ba, $15, $ce, $ab, $b0, $2a, $60, $bc, $f1,
    $f0, $9e, $d5, $97, $d8, $4e, $14, $9d, $42, $4d, $2c, $5c, $2b, $a6, $e1, $a7,
    $ef, $25, $33, $7a, $eb, $e7, $1b, $6d, $4c, $52, $26, $62, $b6, $35, $be, $80,
    $01, $bd, $fd, $37, $f9, $47, $55, $71, $b4, $f2, $ff, $27, $fa, $23, $c9, $83,
    $17, $39, $13, $0d, $c7, $86, $16, $ec, $49, $6f, $fe, $34, $05, $8f, $00, $e6,
    $a4, $da, $7b, $c1, $f3, $f4, $d9, $75, $28, $66, $87, $a8, $45, $6c, $20, $e9,
    $77, $93, $7e, $3c, $1e, $74, $f5, $8c, $3e, $94, $d4, $c2, $5a, $06, $0e, $e8,
    $3d, $a9, $b2, $e3, $e4, $22, $cf, $24, $8e, $6b, $8a, $8d, $84, $4a, $d2, $91,
    $88, $79, $57, $a5, $0f, $cd, $b9, $ac, $3b, $aa, $b3, $d1, $ee, $31, $81, $7c,
    $d7, $89, $d3, $96, $43, $c5, $c6, $c3, $69, $7f, $46, $df, $30, $5b, $6e, $e5,
    $08, $95, $9b, $fb, $b8, $58, $0c, $61, $50, $5d, $3a, $a2, $29, $12, $fc, $51,
    $7d, $1a, $02, $65, $54, $5e, $19, $cc, $dc, $db, $73, $ed, $ad, $59, $2f, $a3);
  m1_address_0_7_xor: TTable = (
    $f4, $bc, $02, $f7, $2c, $3d, $e8, $d9, $50, $62, $ec, $bd, $53, $73, $79, $61,
    $00, $34, $cf, $a2, $63, $28, $90, $af, $44, $3b, $c5, $8d, $3a, $46, $07, $70,
    $66, $be, $d8, $8b, $e9, $a0, $4b, $98, $dc, $df, $e2, $16, $74, $f1, $37, $f5,
    $b7, $21, $81, $01, $1c, $1b, $94, $36, $09, $a1, $4a, $91, $30, $92, $9b, $9a,
    $29, $b1, $38, $4d, $55, $f2, $56, $18, $24, $47, $9d, $3f, $80, $1f, $22, $a4,
    $11, $54, $84, $0d, $25, $48, $ee, $c6, $59, $15, $03, $7a, $fd, $6c, $c3, $33,
    $5b, $c4, $7b, $5a, $05, $7f, $a6, $40, $a9, $5d, $41, $8a, $96, $52, $d3, $f0,
    $ab, $72, $10, $88, $6f, $95, $7c, $a8, $cd, $9c, $5f, $32, $ae, $85, $39, $ac,
    $e5, $d7, $fb, $d4, $08, $23, $19, $65, $6b, $a7, $93, $bb, $2b, $bf, $b8, $35,
    $d0, $06, $26, $68, $3e, $dd, $b9, $69, $2a, $b2, $de, $87, $45, $58, $ff, $3c,
    $9e, $7d, $da, $ed, $49, $8c, $14, $8e, $75, $2f, $e0, $6e, $78, $6d, $20, $d2,
    $fa, $2d, $51, $cc, $c7, $e7, $1d, $27, $97, $fc, $31, $db, $f8, $42, $e3, $99,
    $5e, $83, $0e, $b4, $2e, $f6, $c0, $0c, $4c, $57, $b6, $64, $0a, $17, $a3, $c1,
    $77, $12, $fe, $e6, $8f, $13, $71, $e4, $f9, $ad, $9f, $ce, $d5, $89, $7e, $0f,
    $c2, $86, $f3, $67, $ba, $60, $43, $c9, $04, $b3, $b0, $1e, $b5, $c8, $eb, $a5,
    $76, $ea, $5c, $82, $1a, $4f, $aa, $ca, $e1, $0b, $4e, $cb, $6a, $ef, $d1, $d6);

function Bits(Value: Integer; const Order: array of Integer): Integer;
begin
  Result := 0;
  for var Bit in Order do
    Result := (Result shl 1) or ((Value shr Bit) and 1);
end;

procedure DecryptCMC(var Graphics, Fixed, Audio: TBytes; Key: Byte; CMC50, ExtractFixed, EncryptedAudio: Boolean);
var
  T03, T12, U03, U12, A8a, A8b, A16a, A16b, A0: TTable;
  Buffer: TBytes;

  procedure Pair(Position, Left, Right: Integer; const Hi, Lo, XorTable: TTable; Invert: Boolean);
  begin
    var Temp := XorTable[(Position and $FF) xor A0[(Position shr 8) and $FF]];
    var X0 := (Hi[(Position shr 8) and $FF] and $FE) or (Temp and 1);
    var X1 := (Temp and $FE) or (Lo[(Position shr 8) and $FF] and 1);
    var L := Left;
    var R := Right;
    if Invert then
    begin
      L := Right;
      R := Left;
    end;
    Buffer[Position * 4 + Left] := Graphics[Position * 4 + L] xor X0;
    Buffer[Position * 4 + Right] := Graphics[Position * 4 + R] xor X1;
  end;

begin
  if (Length(Graphics) = 0) or (Length(Graphics) mod 4 <> 0) then
    raise EReadError.Create('Invalid CMC graphics size');
  if CMC50 then
  begin
    T03 := kof2000_type0_t03;
    T12 := kof2000_type0_t12;
    U03 := kof2000_type1_t03;
    U12 := kof2000_type1_t12;
    A8a := kof2000_address_8_15_xor1;
    A8b := kof2000_address_8_15_xor2;
    A16a := kof2000_address_16_23_xor1;
    A16b := kof2000_address_16_23_xor2;
    A0 := kof2000_address_0_7_xor;
  end
  else
  begin
    T03 := kof99_type0_t03;
    T12 := kof99_type0_t12;
    U03 := kof99_type1_t03;
    U12 := kof99_type1_t12;
    A8a := kof99_address_8_15_xor1;
    A8b := kof99_address_8_15_xor2;
    A16a := kof99_address_16_23_xor1;
    A16b := kof99_address_16_23_xor2;
    A0 := kof99_address_0_7_xor;
  end;
  SetLength(Buffer, Length(Graphics));
  for var Position := 0 to Length(Graphics) div 4 - 1 do
  begin
    Pair(Position, 0, 3, T03, T12, U03, ((Position shr 8) and 1) <> 0);
    Pair(Position, 1, 2, T12, T03, U12,
      (((Position shr 16) xor A16b[(Position shr 8) and $FF]) and 1) <> 0);
  end;
  for var Position := 0 to Length(Graphics) div 4 - 1 do
  begin
    var Base := Position xor Key;
    Base := Base xor (Integer(A8a[(Base shr 16) and $FF]) shl 8);
    Base := Base xor (Integer(A8b[Base and $FF]) shl 8);
    Base := Base xor (Integer(A16a[Base and $FF]) shl 16);
    Base := Base xor (Integer(A16b[(Base shr 8) and $FF]) shl 16);
    Base := Base xor A0[(Base shr 8) and $FF];
    if Length(Graphics) = $3000000 then
    begin
      if Position < $800000 then
        Base := Base and $7FFFFF
      else
        Base := $800000 + (Base and $3FFFFF);
    end
    else if Length(Graphics) = $6000000 then
    begin
      if Position < $1000000 then
        Base := Base and $FFFFFF
      else
        Base := $1000000 + (Base and $3FFFFF);
    end
    else
      Base := Base and (Length(Graphics) div 4 - 1);
    for var I := 0 to 3 do
      Graphics[Position * 4 + I] := Buffer[Base * 4 + I];
  end;
  if ExtractFixed then
    ExtractCMCText(Graphics, Fixed);
  if CMC50 and EncryptedAudio then
    DecryptCMCAudio(Audio);
end;

procedure ExtractCMCText(const Graphics: TBytes; var Fixed: TBytes);
begin
  if (Length(Fixed) > Length(Graphics)) or (Length(Fixed) mod 32 <> 0) then
    raise EReadError.Create('Invalid CMC fixed layer size');
  for var I := 0 to Length(Fixed) - 1 do
    Fixed[I] := Graphics[Length(Graphics) - Length(Fixed) + (I and $7FFFFFE0) +
        ((I and 7) shl 2) + (((not I) and 8) shr 2) + ((I and $10) shr 4)];
end;

procedure DecryptCMCAudio(var Audio: TBytes);
const
  M1Order: array[0..7, 0..15] of Integer = (
    (4, 5, 9, 6, 13, 11, 12, 0, 8, 3, 2, 1, 7, 10, 14, 15),
    (12, 6, 0, 10, 14, 4, 13, 5, 3, 2, 9, 15, 11, 8, 1, 7),
    (9, 12, 11, 13, 5, 2, 0, 4, 1, 15, 7, 10, 3, 14, 6, 8),
    (5, 14, 12, 1, 10, 0, 6, 13, 7, 11, 4, 3, 9, 15, 8, 2),
    (11, 0, 2, 5, 12, 7, 4, 9, 10, 8, 3, 14, 15, 6, 13, 1),
    (13, 10, 5, 8, 1, 12, 14, 6, 2, 9, 0, 7, 4, 3, 15, 11),
    (2, 4, 7, 12, 0, 3, 9, 11, 14, 1, 15, 6, 8, 13, 5, 10),
    (6, 1, 13, 15, 8, 5, 10, 14, 11, 4, 12, 2, 0, 7, 3, 9));
var
  Buffer: TBytes;
begin
  if (Length(Audio) < $10000) or (Length(Audio) > $80000) then
    raise EReadError.Create('Invalid CMC50 audio size');
  SetLength(Audio, $80000);
  var Sum := 0;
  for var I := 0 to $FFFF do
    Sum := (Sum + Audio[I]) and $FFFF;
  var AudioKey := Bits(Sum, [12, 0, 2, 4, 8, 15, 7, 13, 10, 1, 3, 6, 11, 9, 14, 5]);
  SetLength(Buffer, $80000);
  for var I := 0 to $7FFFF do
  begin
    var Block := I shr 16;
    var Address := Bits((I and $FFFF) xor AudioKey, M1Order[Block]);
    Address := Address xor m1_address_0_7_xor[(Address shr 8) and $FF];
    Address := Address xor (Integer(m1_address_8_15_xor[Address and $FF]) shl 8);
    Address := Bits(Address, [7, 15, 14, 6, 5, 13, 12, 4, 11, 3, 10, 2, 9, 1, 8, 0]);
    Buffer[I] := Audio[Block * $10000 + Address];
  end;
  Audio := Buffer;
end;

procedure DecryptPCM(var Samples: TBytes; BlockSize, Variant: Integer);
const
  Addresses: array[0..6, 0..1] of Integer = (($000000, $A5000), ($FFCE20, $01000),
    ($FE2CF6, $4E001), ($FFAC28, $C2000), ($FEB2C0, $0A000), ($FF14EA, $A7001), ($FFB440, $02000));
  Xors: array[0..6, 0..7] of Byte = (($F9, $E0, $5D, $F3, $EA, $92, $BE, $EF),
    ($C4, $83, $A8, $5F, $21, $27, $64, $AF), ($C3, $FD, $81, $AC, $6D, $E7, $BF, $9E),
    ($C3, $FD, $81, $AC, $6D, $E7, $BF, $9E), ($CB, $29, $7D, $43, $D2, $3A, $C2, $B4),
    ($4B, $A4, $63, $46, $F0, $91, $EA, $62), ($4B, $A4, $63, $46, $F0, $91, $EA, $62));
begin
  var Buffer := Copy(Samples);
  if BlockSize <> 0 then
  begin
    if not (BlockSize in [4, 8, 16]) or (Length(Samples) mod BlockSize <> 0) then
      raise EReadError.Create('Invalid PCM2 sample size');
    for var I := 0 to Length(Samples) - 1 do
      Samples[I] := Buffer[I xor (BlockSize div 2)];
  end
  else
  begin
    if (Variant < 0) or (Variant > 6) or (Length(Samples) <> $1000000) then
      raise EReadError.Create('Invalid late PCM2 sample size');
    for var I := 0 to $FFFFFF do
    begin
      // Only address bits zero and sixteen change places.
      var J := ((I and $FEFFFE) or ((I and 1) shl 16) or ((I shr 16) and 1)) xor Addresses[Variant, 1];
      var Source := (I + Addresses[Variant, 0]) and $FFFFFF;
      Samples[J] := Buffer[Source] xor Xors[Variant, J and 7];
    end;
  end;
end;

procedure ReorderProgram(var ProgramData: TBytes; const Kind: string);
const
  KOF: array[0..7] of Integer = ($100000, $280000, $300000, $180000, 0, $380000, $200000, $080000);
  S5: array[0..15] of Integer = (0, $080000, $700000, $680000, $500000, $180000, $200000, $480000,
    $300000, $780000, $600000, $280000, $100000, $580000, $400000, $380000);
  SP: array[0..15] of Integer = (0, $080000, $500000, $480000, $600000, $580000, $700000, $280000,
    $100000, $680000, $400000, $780000, $200000, $380000, $300000, $180000);
begin
  var Buffer := Copy(ProgramData);
  var Base := 0;
  var Count := 16;
  if (Kind = 'kof2002') or (Kind = 'matrim') then
  begin
    Base := $100000;
    Count := 8;
  end;
  if Length(Buffer) < Base + Count * $80000 then
    raise EReadError.Create('Truncated encrypted program');
  for var Block := 0 to Count - 1 do
  begin
    var Source: Integer;
    if Count = 8 then
      Source := KOF[Block]
    else if Kind = 'samsho5' then
      Source := S5[Block]
    else if Kind = 'samsh5sp' then
      Source := SP[Block]
    else
      raise ENotSupportedException.Create('Unknown program permutation');
    for var I := 0 to $7FFFF do
      ProgramData[Base + Block * $80000 + I] := Buffer[Base + Source + I];
  end;
end;

procedure DecryptSMA(var ProgramData: TBytes; const Kind: string);
var
  Words, Buffer: TArray<Word>;

  procedure Data(const Order: array of Integer);
  begin
    for var I := $80000 to $47FFFF do
      Words[I] := Word(Bits(Words[I], Order));
  end;

  procedure FixedPart(Source: Integer; const Order: array of Integer);
  begin
    for var I := 0 to $5FFFF do
      Words[I] := Words[Source div 2 + Bits(I, Order)];
  end;

  procedure Banks(Count, BlockSize: Integer; const Order: array of Integer);
  begin
    SetLength(Buffer, BlockSize div 2);
    for var Block := 0 to Count div BlockSize - 1 do
    begin
      var Base := $80000 + Block * (BlockSize div 2);
      for var I := 0 to High(Buffer) do
        Buffer[I] := Words[Base + I];
      for var I := 0 to High(Buffer) do
        Words[Base + I] := Buffer[Bits(I, Order)];
    end;
  end;

begin
  if Length(ProgramData) <> $900000 then
    raise EReadError.Create('Invalid SMA program size');
  SetLength(Words, $480000);
  for var I := 0 to High(Words) do
    Words[I] := Word(Integer(ProgramData[I * 2]) * 256 + ProgramData[I * 2 + 1]);
  if Kind = 'kof99' then
  begin
    Data([13, 7, 3, 0, 9, 4, 5, 6, 1, 12, 8, 14, 10, 11, 2, 15]);
    Banks($600000, $800, [6, 2, 4, 9, 8, 3, 1, 7, 0, 5]);
    FixedPart($700000, [18, 11, 6, 14, 17, 16, 5, 8, 10, 12, 0, 4, 3, 2, 7, 9, 15, 13, 1]);
  end
  else if Kind = 'garou' then
  begin
    Data([13, 12, 14, 10, 8, 2, 3, 1, 5, 9, 11, 4, 15, 0, 6, 7]);
    FixedPart($710000, [18, 4, 5, 16, 14, 7, 9, 6, 13, 17, 15, 3, 1, 2, 12, 11, 8, 10, 0]);
    Banks($800000, $8000, [9, 4, 8, 3, 13, 6, 2, 7, 0, 12, 1, 11, 10, 5]);
  end
  else if Kind = 'garouh' then
  begin
    Data([14, 5, 1, 11, 7, 4, 10, 15, 3, 12, 8, 13, 0, 2, 9, 6]);
    FixedPart($7f8000, [18, 5, 16, 11, 2, 6, 7, 17, 3, 12, 8, 14, 4, 0, 9, 1, 10, 15, 13]);
    Banks($800000, $8000, [12, 8, 1, 7, 11, 3, 13, 10, 6, 9, 5, 4, 0, 2]);
  end
  else if Kind = 'mslug3' then
  begin
    Data([4, 11, 14, 3, 1, 13, 0, 7, 2, 8, 12, 15, 10, 9, 5, 6]);
    FixedPart($5d0000, [18, 15, 2, 1, 13, 3, 0, 9, 6, 16, 4, 11, 5, 7, 12, 17, 14, 10, 8]);
    Banks($800000, $10000, [2, 11, 0, 14, 6, 4, 13, 8, 9, 3, 10, 7, 5, 12, 1]);
  end
  else if Kind = 'mslug3a' then
  begin
    Data([2, 11, 12, 14, 9, 3, 1, 4, 13, 7, 6, 8, 10, 15, 0, 5]);
    FixedPart($5d0000, [18, 1, 16, 14, 7, 17, 5, 8, 4, 15, 6, 3, 2, 0, 13, 10, 12, 9, 11]);
    Banks($800000, $10000, [12, 0, 11, 3, 4, 13, 6, 8, 14, 7, 5, 2, 10, 9, 1]);
  end
  else if Kind = 'kof2000' then
  begin
    Data([12, 8, 11, 3, 15, 14, 7, 0, 10, 13, 6, 5, 9, 2, 1, 4]);
    Banks($63A000, $800, [4, 1, 3, 8, 6, 2, 7, 0, 9, 5]);
    FixedPart($73a000, [18, 8, 4, 15, 13, 3, 14, 16, 2, 6, 17, 7, 12, 10, 0, 5, 11, 1, 9]);
  end
  else
    raise ENotSupportedException.Create('Unknown SMA cartridge');
  for var I := 0 to High(Words) do
  begin
    ProgramData[I * 2] := Words[I] shr 8;
    ProgramData[I * 2 + 1] := Words[I] and $FF;
  end;
end;

function SMABank(const Kind: string; Value: Word): Integer;
const
  kof99: array[0..63] of Integer = (
    $000000, $100000, $200000, $300000, $3cc000, $4cc000, $3f2000, $4f2000,
    $407800, $507800, $40d000, $50d000, $417800, $517800, $420800, $520800,
    $424800, $524800, $429000, $529000, $42e800, $52e800, $431800, $531800,
    $54d000, $551000, $567000, $592800, $588800, $581800, $599800, $594800,
    $598000, $0, $0, $0, $0, $0, $0, $0,
    $0, $0, $0, $0, $0, $0, $0, $0,
    $0, $0, $0, $0, $0, $0, $0, $0,
    $0, $0, $0, $0, $0, $0, $0, $0);
  garou: array[0..63] of Integer = (
    $000000, $100000, $200000, $300000, $280000, $380000, $2d0000, $3d0000,
    $2f0000, $3f0000, $400000, $500000, $420000, $520000, $440000, $540000,
    $498000, $598000, $4a0000, $5a0000, $4a8000, $5a8000, $4b0000, $5b0000,
    $4b8000, $5b8000, $4c0000, $5c0000, $4c8000, $5c8000, $4d0000, $5d0000,
    $458000, $558000, $460000, $560000, $468000, $568000, $470000, $570000,
    $478000, $578000, $480000, $580000, $488000, $588000, $490000, $590000,
    $5d0000, $5d8000, $5e0000, $5e8000, $5f0000, $5f8000, $600000, $0,
    $0, $0, $0, $0, $0, $0, $0, $0);
  garouh: array[0..63] of Integer = (
    $000000, $100000, $200000, $300000, $280000, $380000, $2d0000, $3d0000,
    $2c8000, $3c8000, $400000, $500000, $420000, $520000, $440000, $540000,
    $598000, $698000, $5a0000, $6a0000, $5a8000, $6a8000, $5b0000, $6b0000,
    $5b8000, $6b8000, $5c0000, $6c0000, $5c8000, $6c8000, $5d0000, $6d0000,
    $458000, $558000, $460000, $560000, $468000, $568000, $470000, $570000,
    $478000, $578000, $480000, $580000, $488000, $588000, $490000, $590000,
    $5d8000, $6d8000, $5e0000, $6e0000, $5e8000, $6e8000, $6e8000, $000000,
    $000000, $000000, $000000, $000000, $000000, $000000, $000000, $000000);
  mslug3: array[0..63] of Integer = (
    $000000, $020000, $040000, $060000, $070000, $090000, $0b0000, $0d0000,
    $0e0000, $0f0000, $120000, $130000, $140000, $150000, $180000, $190000,
    $1a0000, $1b0000, $1e0000, $1f0000, $200000, $210000, $240000, $250000,
    $260000, $270000, $2a0000, $2b0000, $2c0000, $2d0000, $300000, $310000,
    $320000, $330000, $360000, $370000, $380000, $390000, $3c0000, $3d0000,
    $400000, $410000, $440000, $450000, $460000, $470000, $4a0000, $4b0000,
    $4c0000, $0, $0, $0, $0, $0, $0, $0,
    $0, $0, $0, $0, $0, $0, $0, $0);
  mslug3a: array[0..63] of Integer = (
    $000000, $030000, $040000, $070000, $080000, $0a0000, $0c0000, $0e0000,
    $0f0000, $100000, $130000, $140000, $150000, $160000, $190000, $1a0000,
    $1B0000, $1C0000, $1F0000, $200000, $210000, $220000, $250000, $260000,
    $270000, $280000, $2B0000, $2C0000, $2D0000, $2E0000, $310000, $320000,
    $330000, $340000, $370000, $380000, $390000, $3A0000, $3D0000, $3E0000,
    $400000, $410000, $440000, $450000, $460000, $470000, $4A0000, $4B0000,
    $4C0000, $0, $0, $0, $0, $0, $0, $0,
    $0, $0, $0, $0, $0, $0, $0, $0);
  kof2000: array[0..63] of Integer = (
    $000000, $100000, $200000, $300000, $3f7800, $4f7800, $3ff800, $4ff800,
    $407800, $507800, $40f800, $50f800, $416800, $516800, $41d800, $51d800,
    $424000, $524000, $523800, $623800, $526000, $626000, $528000, $628000,
    $52a000, $62a000, $52b800, $62b800, $52d000, $62d000, $52e800, $62e800,
    $618000, $619000, $61a000, $61a800, $0, $0, $0, $0,
    $0, $0, $0, $0, $0, $0, $0, $0,
    $0, $0, $0, $0, $0, $0, $0, $0,
    $0, $0, $0, $0, $0, $0, $0, $0);
begin
  if Kind = 'kof99' then
    Result := $100000 + kof99[Bits(Value, [5, 12, 10, 8, 6, 14])]
  else if Kind = 'garou' then
    Result := $100000 + garou[Bits(Value, [12, 14, 6, 7, 9, 5])]
  else if Kind = 'garouh' then
    Result := $100000 + garouh[Bits(Value, [13, 11, 2, 14, 8, 4])]
  else if Kind = 'mslug3' then
    Result := $100000 + mslug3[Bits(Value, [9, 3, 6, 15, 12, 14])]
  else if Kind = 'mslug3a' then
    Result := $100000 + mslug3a[Bits(Value, [11, 12, 6, 1, 3, 15])]
  else if Kind = 'kof2000' then
    Result := $100000 + kof2000[Bits(Value, [5, 10, 3, 7, 14, 15])]
  else
    raise ENotSupportedException.Create('Unknown SMA bank');
end;

procedure DecryptPVC(var ProgramData: TBytes; const Kind: string);
const
  mslug5_xor1: TXorTable = (
    $c2, $4b, $74, $fd, $0b, $34, $eb, $d7, $10, $6d, $f9, $ce, $5d, $d5, $61, $29,
    $f5, $be, $0d, $82, $72, $45, $0f, $24, $b3, $34, $1b, $99, $ea, $09, $f3, $03);
  mslug5_xor2: TXorTable = (
    $36, $09, $b0, $64, $95, $0f, $90, $42, $6e, $0f, $30, $f6, $e5, $08, $30, $64,
    $08, $04, $00, $2f, $72, $09, $a0, $13, $c9, $0b, $a0, $3e, $c2, $00, $40, $2b);
  svc_xor1: TXorTable = (
    $3b, $6a, $f7, $b7, $e8, $a9, $20, $99, $9f, $39, $34, $0c, $c3, $9a, $a5, $c8,
    $b8, $18, $ce, $56, $94, $44, $e3, $7a, $f7, $dd, $42, $f0, $18, $60, $92, $9f);
  svc_xor2: TXorTable = (
    $69, $0b, $60, $d6, $4f, $01, $40, $1a, $9f, $0b, $f0, $75, $58, $0e, $60, $b4,
    $14, $04, $20, $e4, $b9, $0d, $10, $89, $eb, $07, $30, $90, $50, $0e, $20, $26);
  kof2003_xor1: TXorTable = (
    $3b, $6a, $f7, $b7, $e8, $a9, $20, $99, $9f, $39, $34, $0c, $c3, $9a, $a5, $c8,
    $b8, $18, $ce, $56, $94, $44, $e3, $7a, $f7, $dd, $42, $f0, $18, $60, $92, $9f);
  kof2003_xor2: TXorTable = (
    $2f, $02, $60, $bb, $77, $01, $30, $08, $d8, $01, $a0, $df, $37, $0a, $f0, $65,
    $28, $03, $d0, $23, $d3, $03, $70, $42, $bb, $06, $f0, $28, $ba, $0f, $f0, $7a);
  kof2003h_xor1: TXorTable = (
    $c2, $4b, $74, $fd, $0b, $34, $eb, $d7, $10, $6d, $f9, $ce, $5d, $d5, $61, $29,
    $f5, $be, $0d, $82, $72, $45, $0f, $24, $b3, $34, $1b, $99, $ea, $09, $f3, $03);
  kof2003h_xor2: TXorTable = (
    $2b, $09, $d0, $7f, $51, $0b, $10, $4c, $5b, $07, $70, $9d, $3e, $0b, $b0, $b6,
    $54, $09, $e0, $cc, $3d, $0d, $80, $99, $87, $03, $90, $82, $fe, $04, $20, $18);
  pcb_xor2: TXorTable = ($B4, $0F, $40, $6C, $38, $07, $D0, $3F, $53, $08, $80, $AA, $BE, $07, $C0, $FA,
    $D0, $08, $10, $D2, $F1, $03, $70, $7E, $87, $0B, $40, $F6, $2A, $0A, $E0, $F9);
  pcb_data: array[0..15] of Integer = (15, 14, 13, 12, 4, 5, 6, 7, 8, 9, 10, 11, 3, 2, 1, 0);
  pcb_banks: array[0..7] of Integer = (4, 5, 6, 7, 1, 0, 3, 2);
  pcb_fixed: array[0..7] of Integer = (7, 6, 5, 4, 1, 0, 3, 2);
var
  X1, X2: TXorTable;
  DOrder: array[0..15] of Integer;
  BOrder, FOrder: array[0..7] of Integer;
  AddressXor: Integer;
  Buffer: TBytes;
begin
  if Kind = 'kf2k3pcb' then
  begin
    FillChar(X1, SizeOf(X1), 0);
    X2 := pcb_xor2;
    AddressXor := $300;
    for var I := 0 to 15 do
      DOrder[I] := pcb_data[I];
    for var I := 0 to 7 do
    begin
      BOrder[I] := pcb_banks[I];
      FOrder[I] := pcb_fixed[I];
    end;
  end
  else if Kind = 'mslug5' then
  begin
    X1 := mslug5_xor1;
    X2 := mslug5_xor2;
    AddressXor := $00700;
    DOrder[0] := 15;
    DOrder[1] := 14;
    DOrder[2] := 13;
    DOrder[3] := 12;
    DOrder[4] := 10;
    DOrder[5] := 11;
    DOrder[6] := 8;
    DOrder[7] := 9;
    DOrder[8] := 6;
    DOrder[9] := 7;
    DOrder[10] := 4;
    DOrder[11] := 5;
    DOrder[12] := 3;
    DOrder[13] := 2;
    DOrder[14] := 1;
    DOrder[15] := 0;
    BOrder[0] := 5;
    BOrder[1] := 4;
    BOrder[2] := 7;
    BOrder[3] := 6;
    BOrder[4] := 1;
    BOrder[5] := 0;
    BOrder[6] := 3;
    BOrder[7] := 2;
    FOrder[0] := 7;
    FOrder[1] := 6;
    FOrder[2] := 5;
    FOrder[3] := 4;
    FOrder[4] := 1;
    FOrder[5] := 0;
    FOrder[6] := 3;
    FOrder[7] := 2;
  end
  else if Kind = 'svc' then
  begin
    X1 := svc_xor1;
    X2 := svc_xor2;
    AddressXor := $00a00;
    DOrder[0] := 15;
    DOrder[1] := 14;
    DOrder[2] := 13;
    DOrder[3] := 12;
    DOrder[4] := 10;
    DOrder[5] := 11;
    DOrder[6] := 8;
    DOrder[7] := 9;
    DOrder[8] := 6;
    DOrder[9] := 7;
    DOrder[10] := 4;
    DOrder[11] := 5;
    DOrder[12] := 3;
    DOrder[13] := 2;
    DOrder[14] := 1;
    DOrder[15] := 0;
    BOrder[0] := 4;
    BOrder[1] := 5;
    BOrder[2] := 6;
    BOrder[3] := 7;
    BOrder[4] := 1;
    BOrder[5] := 0;
    BOrder[6] := 3;
    BOrder[7] := 2;
    FOrder[0] := 7;
    FOrder[1] := 6;
    FOrder[2] := 5;
    FOrder[3] := 4;
    FOrder[4] := 2;
    FOrder[5] := 3;
    FOrder[6] := 0;
    FOrder[7] := 1;
  end
  else if Kind = 'kof2003' then
  begin
    X1 := kof2003_xor1;
    X2 := kof2003_xor2;
    AddressXor := $00800;
    DOrder[0] := 15;
    DOrder[1] := 14;
    DOrder[2] := 13;
    DOrder[3] := 12;
    DOrder[4] := 5;
    DOrder[5] := 4;
    DOrder[6] := 7;
    DOrder[7] := 6;
    DOrder[8] := 9;
    DOrder[9] := 8;
    DOrder[10] := 11;
    DOrder[11] := 10;
    DOrder[12] := 3;
    DOrder[13] := 2;
    DOrder[14] := 1;
    DOrder[15] := 0;
    BOrder[0] := 4;
    BOrder[1] := 5;
    BOrder[2] := 6;
    BOrder[3] := 7;
    BOrder[4] := 1;
    BOrder[5] := 0;
    BOrder[6] := 3;
    BOrder[7] := 2;
    FOrder[0] := 7;
    FOrder[1] := 6;
    FOrder[2] := 5;
    FOrder[3] := 4;
    FOrder[4] := 0;
    FOrder[5] := 1;
    FOrder[6] := 2;
    FOrder[7] := 3;
  end
  else if Kind = 'kof2003h' then
  begin
    X1 := kof2003h_xor1;
    X2 := kof2003h_xor2;
    AddressXor := $00400;
    DOrder[0] := 15;
    DOrder[1] := 14;
    DOrder[2] := 13;
    DOrder[3] := 12;
    DOrder[4] := 10;
    DOrder[5] := 11;
    DOrder[6] := 8;
    DOrder[7] := 9;
    DOrder[8] := 6;
    DOrder[9] := 7;
    DOrder[10] := 4;
    DOrder[11] := 5;
    DOrder[12] := 3;
    DOrder[13] := 2;
    DOrder[14] := 1;
    DOrder[15] := 0;
    BOrder[0] := 6;
    BOrder[1] := 7;
    BOrder[2] := 4;
    BOrder[3] := 5;
    BOrder[4] := 0;
    BOrder[5] := 1;
    BOrder[6] := 2;
    BOrder[7] := 3;
    FOrder[0] := 7;
    FOrder[1] := 6;
    FOrder[2] := 5;
    FOrder[3] := 4;
    FOrder[4] := 1;
    FOrder[5] := 0;
    FOrder[6] := 3;
    FOrder[7] := 2;
  end
  else
    raise ENotSupportedException.Create('Unknown PVC cartridge');
  var Size := $800000;
  if (Kind = 'kof2003') or (Kind = 'kof2003h') or (Kind = 'kf2k3pcb') then
    Size := $900000;
  if Length(ProgramData) <> Size then
    raise EReadError.Create('Invalid PVC program size');
  if Size = $900000 then
    for var I := 0 to $FFFFF do
      ProgramData[$800000 + I] := ProgramData[$800000 + I] xor ProgramData[$100002 or I];
  for var I := 0 to $FFFFF do
    ProgramData[I] := ProgramData[I] xor X1[(I xor 1) and 31];
  for var I := $100000 to $7FFFFF do
    ProgramData[I] := ProgramData[I] xor X2[(I xor 1) and 31];
  for var I := $40000 to $1FFFFF do
  begin
    var Base := I * 4;
    var Value := Bits(Integer(ProgramData[Base]) or (Integer(ProgramData[Base + 3]) shl 8), DOrder);
    ProgramData[Base] := Value and $FF;
    ProgramData[Base + 3] := Value shr 8;
  end;
  Buffer := Copy(ProgramData);
  for var Block := 0 to 15 do
  begin
    var Source := Bits(Block, FOrder) * $10000;
    for var I := 0 to $FFFF do
      Buffer[Block * $10000 + I] := ProgramData[Source + I];
  end;
  for var Block := $1000 to Size div $100 - 1 do
  begin
    var Base := Block * $100;
    var Source := (Base and $F000FF) + ((Base and $F00) xor AddressXor) +
      (Bits((Base shr 12) and $FF, BOrder) shl 12);
    for var I := 0 to $FF do
      Buffer[Base + I] := ProgramData[Source + I];
  end;
  for var I := 0 to $FFFFF do
    ProgramData[I] := Buffer[I];
  for var I := 0 to $FFFFF do
    ProgramData[$100000 + I] := Buffer[Size - $100000 + I];
  for var I := 0 to Size - $200000 - 1 do
    ProgramData[$200000 + I] := Buffer[$100000 + I];
end;

procedure DecryptKOF98(var ProgramData: TBytes);
const
  Sections: array[0..7] of Integer = (0, $100000, 4, $100004, $10000A, $A, $10000E, $E);
  Positions: array[0..3] of Integer = (0, 4, $A, $E);
begin
  if Length(ProgramData) < $600000 then
    raise EReadError.Create('Invalid KOF98 program size');
  var Buffer := Copy(ProgramData, 0, $200000);
  for var Block := 4 to $7FF do
  begin
    var Base := Block * $200;
    for var Row := 0 to 15 do
    begin
      var J := Base + Row * $10;
      for var K := 0 to 7 do
        for var B := 0 to 1 do
        begin
          ProgramData[J + K * 2 + B] := Buffer[J + Sections[K] + $100 + B];
          ProgramData[J + K * 2 + $100 + B] := Buffer[J + Sections[K] + B];
        end;
      if Base >= $80000 then
        for var Position in Positions do
          for var B := 0 to 1 do
          begin
            var Swap := 0;
            if Base >= $C0000 then
              Swap := $100;
            ProgramData[J + Position + B] := Buffer[J + Position + Swap + B];
            ProgramData[J + Position + $100 + B] := Buffer[J + Position + (Swap xor $100) + B];
          end;
    end;
    for var B := 0 to 1 do
    begin
      ProgramData[Base + B] := Buffer[Base + B];
      ProgramData[Base + 2 + B] := Buffer[Base + $100000 + B];
      ProgramData[Base + $100 + B] := Buffer[Base + $100 + B];
      ProgramData[Base + $102 + B] := Buffer[Base + $100100 + B];
    end;
  end;
  for var I := 0 to $3FFFFF do
    ProgramData[$100000 + I] := ProgramData[$200000 + I];
  SetLength(ProgramData, $500000);
end;

end.

