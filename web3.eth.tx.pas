{******************************************************************************}
{                                                                              }
{                                  Delphereum                                  }
{                                                                              }
{             Copyright(c) 2018 Stefan van As <svanas@runbox.com>              }
{           Github Repository <https://github.com/svanas/delphereum>           }
{                                                                              }
{   Distributed under Creative Commons NonCommercial (aka CC BY-NC) license.   }
{                                                                              }
{******************************************************************************}

unit web3.eth.tx;

{$I web3.inc}

interface

uses
  // Delphi
  System.JSON,
  System.SysUtils,
  // Velthuis' BigNumbers
  Velthuis.BigIntegers,
  // CryptoLib4Pascal
  ClpBigInteger,
  // web3
  web3,
  web3.crypto,
  web3.eth,
  web3.eth.crypto,
  web3.eth.gas,
  web3.eth.types,
  web3.eth.utils,
  web3.json,
  web3.json.rpc,
  web3.rlp,
  web3.types,
  web3.utils;

function signTransaction(
  chain     : TChain;
  nonce     : BigInteger;
  from      : TPrivateKey;
  &to       : TAddress;
  value     : TWei;
  const data: string;
  gasPrice  : TWei;
  gasLimit  : TWei): string;

procedure sendTransaction(
  client   : TWeb3;
  const raw: string;
  callback : TASyncTxHash); overload;

procedure sendTransaction(
  client  : TWeb3;
  from    : TPrivateKey;
  &to     : TAddress;
  value   : TWei;
  callback: TASyncTxHash); overload;

procedure sendTransaction(
  client  : TWeb3;
  from    : TPrivateKey;
  &to     : TAddress;
  value   : TWei;
  gasPrice: TWei;
  gasLimit: TWei;
  callback: TASyncTxHash); overload;

// returns the information about a transaction requested by transaction hash.
procedure getTransaction(
  client  : TWeb3;
  hash    : TTxHash;
  callback: TASyncTxn);

// returns the receipt of a transaction by transaction hash.
procedure getTransactionReceipt(
  client  : TWeb3;
  hash    : TTxHash;
  callback: TASyncReceipt);

// get the revert reason for a failed transaction.
procedure getTransactionRevertReason(
  client  : TWeb3;
  rcpt    : ITxReceipt;
  callback: TASyncString);

implementation

function signTransaction(
  chain     : TChain;
  nonce     : BigInteger;
  from      : TPrivateKey;
  &to       : TAddress;
  value     : TWei;
  const data: string;
  gasPrice  : TWei;
  gasLimit  : TWei): string;
var
  Signer   : TEthereumSigner;
  Signature: TECDsaSignature;
  r, s, v  : TBigInteger;
begin
  Signer := TEthereumSigner.Create;
  try
    Signer.Init(True, web3.eth.crypto.PrivateKeyFromHex(from));

    Signature := Signer.GenerateSignature(
      sha3(
        web3.rlp.encode([
          web3.utils.toHex(nonce),    // nonce
          web3.utils.toHex(gasPrice), // gasPrice
          web3.utils.toHex(gasLimit), // gas(Limit)
          &to,                        // to
          web3.utils.toHex(value),    // value
          data,                       // data
          chainId[chain],             // v
          0,                          // r
          0                           // s
        ])
      )
    );

    r := Signature.r;
    s := Signature.s;
    v := Signature.rec.Add(TBigInteger.ValueOf(chainId[chain] * 2 + 35));

    Result :=
      web3.utils.toHex(
        web3.rlp.encode([
          web3.utils.toHex(nonce),                 // nonce
          web3.utils.toHex(gasPrice),              // gasPrice
          web3.utils.toHex(gasLimit),              // gas(Limit)
          &to,                                     // to
          web3.utils.toHex(value),                 // value
          data,                                    // data
          web3.utils.toHex(v.ToByteArrayUnsigned), // v
          web3.utils.toHex(r.ToByteArrayUnsigned), // r
          web3.utils.toHex(s.ToByteArrayUnsigned)  // s
        ])
      );
  finally
    Signer.Free;
  end;
end;

procedure sendTransaction(client: TWeb3; const raw: string; callback: TASyncTxHash);
begin
  web3.json.rpc.send(client.URL, 'eth_sendRawTransaction', [raw], procedure(resp: TJsonObject; err: Exception)
  begin
    if Assigned(err) then
      callback('', err)
    else
      callback(TTxHash(web3.json.GetPropAsStr(resp, 'result')), nil);
  end);
end;

procedure sendTransaction(
  client  : TWeb3;
  from    : TPrivateKey;
  &to     : TAddress;
  value   : TWei;
  callback: TASyncTxHash);
begin
  web3.eth.gas.getGasPrice(client, procedure(gasPrice: BigInteger; err: Exception)
  begin
    if Assigned(err) then
      callback('', err)
    else
      sendTransaction(client, from, &to, value, gasPrice, 21000, callback);
  end);
end;

procedure sendTransaction(
  client  : TWeb3;
  from    : TPrivateKey;
  &to     : TAddress;
  value   : TWei;
  gasPrice: TWei;
  gasLimit: TWei;
  callback: TASyncTxHash);
begin
  web3.eth.getTransactionCount(
    client,
    web3.eth.crypto.AddressFromPrivateKey(web3.eth.crypto.PrivateKeyFromHex(from)),
    procedure(qty: BigInteger; err: Exception)
    begin
      if Assigned(err) then
        callback('', err)
      else
        sendTransaction(client, signTransaction(client.Chain, qty, from, &to, value, '', gasPrice, gasLimit), callback);
    end
  );
end;

{ TTxn }

type
  TTxn = class(TInterfacedObject, ITxn)
  private
    FJsonObject: TJsonObject;
  public
    constructor Create(aJsonObject: TJsonObject);
    destructor Destroy; override;
    function ToString: string; override;
    function blockNumber: BigInteger; // block number where this transaction was in. null when its pending.
    function from: TAddress;          // address of the sender.
    function gasLimit: TWei;          // gas provided by the sender.
    function gasPrice: TWei;          // gas price provided by the sender in Wei.
    function input: string;           // the data send along with the transaction.
    function &to: TAddress;           // address of the receiver. null when its a contract creation transaction.
    function value: TWei;             // value transferred in Wei.
  end;

constructor TTxn.Create(aJsonObject: TJsonObject);
begin
  inherited Create;
  FJsonObject := aJsonObject.Clone as TJsonObject;
end;

destructor TTxn.Destroy;
begin
  if Assigned(FJsonObject) then FJsonObject.Free;
  inherited Destroy;
end;

function TTxn.ToString: string;
begin
  Result := web3.json.marshal(FJsonObject);
end;

// block number where this transaction was in. null when its pending.
function TTxn.blockNumber: BigInteger;
begin
  Result := GetPropAsStr(FJsonObject, 'blockNumber', '0x0');
end;

// address of the sender.
function TTxn.from: TAddress;
begin
  Result := TAddress(GetPropAsStr(FJsonObject, 'from', string(ADDRESS_ZERO)));
end;

// gas provided by the sender.
function TTxn.gasLimit: TWei;
begin
  Result := GetPropAsStr(FJsonObject, 'gas', '0x5208');
end;

// gas price provided by the sender in Wei.
function TTxn.gasPrice: TWei;
begin
  Result := GetPropAsStr(FJsonObject, 'gasPrice', '0x0');
end;

// the data send along with the transaction.
function TTxn.input: string;
begin
  Result := web3.json.GetPropAsStr(FJsonObject, 'input');
end;

// address of the receiver. null when its a contract creation transaction.
function TTxn.&to: TAddress;
begin
  Result := TAddress(GetPropAsStr(FJsonObject, 'to', string(ADDRESS_ZERO)));
end;

// value transferred in Wei.
function TTxn.value: TWei;
begin
  Result := GetPropAsStr(FJsonObject, 'value', '0x0');
end;

// returns the information about a transaction requested by transaction hash.
procedure getTransaction(client: TWeb3; hash: TTxHash; callback: TASyncTxn);
begin
  web3.json.rpc.send(client.URL, 'eth_getTransactionByHash', [hash], procedure(resp: TJsonObject; err: Exception)
  begin
    if Assigned(err) then
      callback(nil, err)
    else
      callback(TTxn.Create(web3.json.GetPropAsObj(resp, 'result')), nil);
  end);
end;

{ TTxReceipt }

type
  TTxReceipt = class(TInterfacedObject, ITxReceipt)
  private
    FJsonObject: TJsonObject;
  public
    constructor Create(aJsonObject: TJsonObject);
    destructor Destroy; override;
    function ToString: string; override;
    function txHash: TTxHash; // hash of the transaction.
    function from: TAddress;  // address of the sender.
    function &to: TAddress;   // address of the receiver. null when it's a contract creation transaction.
    function gasUsed: TWei;   // the amount of gas used by this specific transaction.
    function status: Boolean; // success or failure.
  end;

constructor TTxReceipt.Create(aJsonObject: TJsonObject);
begin
  inherited Create;
  FJsonObject := aJsonObject.Clone as TJsonObject;
end;

destructor TTxReceipt.Destroy;
begin
  if Assigned(FJsonObject) then FJsonObject.Free;
  inherited Destroy;
end;

function TTxReceipt.ToString: string;
begin
  Result := web3.json.marshal(FJsonObject);
end;

// hash of the transaction.
function TTxReceipt.txHash: TTxHash;
begin
  Result := TTxHash(GetPropAsStr(FJsonObject, 'transactionHash', ''));
end;

// address of the sender.
function TTxReceipt.from: TAddress;
begin
  Result := TAddress(GetPropAsStr(FJsonObject, 'from', string(ADDRESS_ZERO)));
end;

// address of the receiver. null when it's a contract creation transaction.
function TTxReceipt.&to: TAddress;
begin
  Result := TAddress(GetPropAsStr(FJsonObject, 'to', string(ADDRESS_ZERO)));
end;

// the amount of gas used by this specific transaction.
function TTxReceipt.gasUsed: TWei;
begin
  Result := GetPropAsStr(FJsonObject, 'gasUsed', '0x0');
end;

// success or failure.
function TTxReceipt.status: Boolean;
begin
  Result := GetPropAsStr(FJsonObject, 'status', '0x1') = '0x1';
end;

// returns the receipt of a transaction by transaction hash.
procedure getTransactionReceipt(client: TWeb3; hash: TTxHash; callback: TASyncReceipt);
begin
  web3.json.rpc.send(client.URL, 'eth_getTransactionReceipt', [hash], procedure(resp: TJsonObject; err: Exception)
  begin
    if Assigned(err) then
      callback(nil, err)
    else
      callback(TTxReceipt.Create(web3.json.GetPropAsObj(resp, 'result')), nil);
  end);
end;

resourcestring
  TX_DID_NOT_FAIL = 'Transaction did not fail';
  TX_OUT_OF_GAS   = 'Transaction ran out of gas';

// get the revert reason for a failed transaction.
procedure getTransactionRevertReason(client: TWeb3; rcpt: ITxReceipt; callback: TASyncString);
var
  decoded,
  encoded: string;
  len: Int64;
  obj: TJsonObject;
begin
  if rcpt.status then
  begin
    callback(TX_DID_NOT_FAIL, nil);
    EXIT;
  end;

  web3.eth.tx.getTransaction(client, rcpt.txHash, procedure(txn: ITxn; err: Exception)
  begin
    if Assigned(err) then
    begin
      callback('', err);
      EXIT;
    end;

    if rcpt.gasUsed = txn.gasLimit then
    begin
      callback(TX_OUT_OF_GAS, nil);
      EXIT;
    end;

    // eth_call the failed transaction *with the block number from the receipt*
    obj := web3.json.unmarshal(Format(
      '{"to": %s, "data": %s, "from": %s, "value": %s, "gas": %s, "gasPrice": %s}', [
        web3.json.QuoteString(string(txn.&to), '"'),
        web3.json.QuoteString(txn.input, '"'),
        web3.json.QuoteString(string(txn.from), '"'),
        web3.json.QuoteString(toHex(txn.value), '"'),
        web3.json.QuoteString(toHex(txn.gasLimit), '"'),
        web3.json.QuoteString(toHex(txn.gasPrice), '"')
      ]
    ));
    try
      web3.json.rpc.send(client.URL, 'eth_call', [obj, toHex(txn.blockNumber)], procedure(resp: TJsonObject; err: Exception)
      begin
        if Assigned(err) then
        begin
          callback('', err);
          EXIT;
        end;

        // parse the reason from the response
        encoded := web3.json.GetPropAsStr(resp, 'result');
        // trim the 0x prefix
        Delete(encoded, Low(encoded), 2);
        // get the length of the revert reason
        len := StrToInt64('$' + Copy(encoded, Low(encoded) + 8 + 64, 64));
        // using the length and known offset, extract the revert reason
        encoded := Copy(encoded, Low(encoded) + 8 + 128, len * 2);
        // convert reason from hex to string
        decoded := TEncoding.UTF8.GetString(fromHex(encoded));

        callback(decoded, nil);
      end);
    finally
      obj.Free;
    end;
  end);
end;

end.
