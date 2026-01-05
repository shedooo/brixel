import { describe, expect, it } from "vitest";
import { Cl, ClarityType, ClarityValue, ResponseOkCV, TupleCV, UIntCV, BooleanCV } from "@stacks/transactions";

const contractName = "brixel";
const accounts = simnet.getAccounts();
const owner = accounts.get("deployer")!;
const admin = accounts.get("wallet_2")!;
const primaryHolder = accounts.get("wallet_4")!;
const secondaryHolder = accounts.get("wallet_5")!;
const multiSigPartner = accounts.get("wallet_6")!;
const backup = accounts.get("wallet_7")!;

const ROLE_ADMIN = 1n;
const ROLE_ASSET_MANAGER = 3n;
const ROLE_EMERGENCY_RESPONDER = 4n;

const toPrincipal = (address: string) => Cl.standardPrincipal(address);
const futureExpiry = () => Cl.uint(BigInt(simnet.blockHeight) + 10_000n);
const contractCall = (method: string, args: any[] = [], sender = owner) =>
  simnet.callPublicFn(contractName, method, args, sender);
const readOnlyCall = (method: string, args: any[] = [], sender = owner) =>
  simnet.callReadOnlyFn(contractName, method, args, sender).result;
const metadataTuple = (description: string, assetType: string, valuation: bigint) =>
  Cl.tuple({
    description: Cl.stringAscii(description),
    "asset-type": Cl.stringAscii(assetType),
    valuation: Cl.uint(valuation),
  });

const applyKyc = (address: string) =>
  contractCall("set-kyc", [toPrincipal(address), Cl.bool(true), futureExpiry()], owner);

const unwrapOk = <T extends ResponseOkCV>(response: unknown): T => {
  const clarityValue = response as ClarityValue;
  if (clarityValue.type !== ClarityType.ResponseOk) {
    throw new Error("expected response to be ok");
  }
  return clarityValue as T;
};

const unwrapUInt = (response: unknown) => {
  const ok = unwrapOk<ResponseOkCV>(response);
  const value = ok.value as UIntCV;
  return value.value as bigint;
};

describe("brixel core flows", () => {
  it("gates role management behind the owner and exposes permissions", () => {
    const assignResult = contractCall(
      "assign-role",
      [toPrincipal(admin), Cl.uint(ROLE_ADMIN)],
      owner,
    );
    expect(assignResult.result).toBeOk(Cl.bool(true));

    const roleForAdmin = readOnlyCall("get-user-role", [toPrincipal(admin)]);
    expect(roleForAdmin).toBeOk(Cl.uint(ROLE_ADMIN));

    const unauthorized = contractCall(
      "assign-role",
      [toPrincipal(secondaryHolder), Cl.uint(ROLE_ASSET_MANAGER)],
      admin,
    );
    expect(unauthorized.result).toBeErr(Cl.uint(401));

    const permissions = readOnlyCall("get-role-permissions", [Cl.uint(ROLE_ADMIN)]);
    expect(permissions).toBeOk(
      Cl.list([
        Cl.stringAscii("mint"),
        Cl.stringAscii("burn"),
        Cl.stringAscii("transfer-ownership"),
        Cl.stringAscii("set-roles"),
        Cl.stringAscii("emergency-pause"),
        Cl.stringAscii("update-metadata"),
        Cl.stringAscii("set-reserve-ratio"),
      ]),
    );

    const batchAssign = contractCall(
      "batch-assign-roles",
      [Cl.list([toPrincipal(backup)]), Cl.uint(ROLE_EMERGENCY_RESPONDER)],
      owner,
    );
    expect(batchAssign.result).toBeOk(Cl.bool(true));

    const backupRole = readOnlyCall("get-user-role", [toPrincipal(backup)]);
    expect(backupRole).toBeOk(Cl.uint(ROLE_EMERGENCY_RESPONDER));
  });

  it("enforces compliance guards around mint, transfer, burn, freeze, and pause", () => {
    applyKyc(primaryHolder);
    applyKyc(secondaryHolder);

    const supplyBefore = readOnlyCall("get-total-supply");
    const supplyBeforeValue: bigint = unwrapUInt(supplyBefore);

    const mintedAmount = 1_000_000n;
    const mintTx = contractCall(
      "mint",
      [toPrincipal(primaryHolder), Cl.uint(mintedAmount), metadataTuple("Unit 101", "residential", 2_000_000n)],
      owner,
    );
    expect(mintTx.result.type).toBe("ok");

    const supplyAfterMint = readOnlyCall("get-total-supply");
    const supplyAfterMintValue: bigint = unwrapUInt(supplyAfterMint);
    expect(supplyAfterMintValue - supplyBeforeValue).toBe(mintedAmount);

    const primaryBalance = readOnlyCall("get-token-balance", [toPrincipal(primaryHolder)]);
    expect(primaryBalance).toBeOk(Cl.uint(mintedAmount));

    const transferAmount = 200_000n;
    const transferResult = contractCall(
      "transfer",
      [toPrincipal(secondaryHolder), Cl.uint(transferAmount)],
      primaryHolder,
    );
    expect(transferResult.result.type).toBe("ok");

    expect(readOnlyCall("get-token-balance", [toPrincipal(primaryHolder)])).toBeOk(
      Cl.uint(mintedAmount - transferAmount),
    );
    expect(readOnlyCall("get-token-balance", [toPrincipal(secondaryHolder)])).toBeOk(
      Cl.uint(transferAmount),
    );

    const freezeResult = contractCall("freeze-account", [toPrincipal(secondaryHolder)], owner);
    expect(freezeResult.result.type).toBe("ok");

    const frozenTransfer = contractCall(
      "transfer",
      [toPrincipal(primaryHolder), Cl.uint(50n)],
      secondaryHolder,
    );
    expect(frozenTransfer.result).toBeErr(Cl.uint(403));

    contractCall("unfreeze-account", [toPrincipal(secondaryHolder)], owner);

    contractCall("pause", [], owner);
    const pausedTransfer = contractCall(
      "transfer",
      [toPrincipal(secondaryHolder), Cl.uint(10n)],
      primaryHolder,
    );
    expect(pausedTransfer.result).toBeErr(Cl.uint(404));
    contractCall("unpause", [], owner);

    const burnAmount = 50_000n;
    const burnResult = contractCall("burn", [Cl.uint(burnAmount)], secondaryHolder);
    expect(burnResult.result.type).toBe("ok");

    const totalAfterBurn = readOnlyCall("get-total-supply");
    const totalAfterBurnValue: bigint = unwrapUInt(totalAfterBurn);
    expect(totalAfterBurnValue - supplyBeforeValue).toBe(mintedAmount - burnAmount);

    expect(readOnlyCall("get-token-balance", [toPrincipal(secondaryHolder)])).toBeOk(
      Cl.uint(transferAmount - burnAmount),
    );
  });

  it("keeps metadata and backing in sync after updates", () => {
    applyKyc(secondaryHolder);

    const mintTx = contractCall(
      "mint",
      [toPrincipal(secondaryHolder), Cl.uint(500n), metadataTuple("Asset B", "industrial", 3_000n)],
      owner,
    );
    expect(mintTx.result.type).toBe("ok");
    const metadataId = unwrapOk<ResponseOkCV>(mintTx.result).value as UIntCV;

    const updateTx = contractCall(
      "update-metadata",
      [metadataId, metadataTuple("Asset B v2", "industrial", 4_200n)],
      owner,
    );
    expect(updateTx.result.type).toBe("ok");

    const enhanced = unwrapOk<ResponseOkCV>(readOnlyCall("get-enhanced-metadata", [metadataId]));
    const metadataFields = (enhanced.value as TupleCV).value;
    expect(metadataFields.description).toBeAscii("Asset B v2");
    expect(metadataFields["asset-type"]).toBeAscii("industrial");
    expect(metadataFields.valuation).toBeUint(4_200n);

    const createdAt = (metadataFields["created-at"] as any).value as bigint;
    const updatedAt = (metadataFields["updated-at"] as any).value as bigint;
    expect(updatedAt).toBeGreaterThanOrEqual(createdAt);

    expect(readOnlyCall("get-asset-backing", [metadataId])).toBeOk(Cl.uint(4_200n));
    expect(readOnlyCall("get-metadata", [metadataId])).toBeOk(Cl.stringAscii("Asset B v2"));

    const contractInfo = unwrapOk<ResponseOkCV>(readOnlyCall("get-contract-info"));
    const contractInfoFields = (contractInfo.value as TupleCV).value;
    const metadataCounter = (contractInfoFields["metadata-counter"] as any).value as bigint;
    expect(metadataCounter).toBeGreaterThanOrEqual(1n);
  });

  it("requires multi-sign approvals for critical operations", () => {
    contractCall("assign-role", [toPrincipal(admin), Cl.uint(ROLE_ADMIN)], owner);
    contractCall("assign-role", [toPrincipal(multiSigPartner), Cl.uint(ROLE_ADMIN)], owner);

    const invalidCreate = contractCall(
      "create-critical-operation",
      [Cl.stringAscii("emergency-pause"), toPrincipal(owner), Cl.uint(0n), Cl.uint(1n)],
      owner,
    );
    expect(invalidCreate.result).toBeErr(Cl.uint(406));

    const createResult = contractCall(
      "create-critical-operation",
      [Cl.stringAscii("emergency-pause"), toPrincipal(owner), Cl.uint(0n), Cl.uint(2n)],
      owner,
    );
    expect(createResult.result.type).toBe("ok");
    const operationId = unwrapOk<ResponseOkCV>(createResult.result).value as UIntCV;

    const canExecuteBefore = unwrapOk<ResponseOkCV>(readOnlyCall("can-execute-operation", [operationId]))
      .value as BooleanCV;
    expect(canExecuteBefore).toBeBool(false);

    const statusBefore = unwrapOk<ResponseOkCV>(readOnlyCall("get-operation-status", [operationId]));
    const statusBeforeFields = (statusBefore.value as TupleCV).value;
    expect(statusBeforeFields["approvals-count"]).toBeUint(1n);
    expect(statusBeforeFields.executed).toBeBool(false);

    const approveResult = contractCall("approve-operation", [operationId], admin);
    expect(approveResult.result.type).toBe("ok");

    const duplicateApproval = contractCall("approve-operation", [operationId], admin);
    expect(duplicateApproval.result).toBeErr(Cl.uint(413));

    const canExecuteAfter = unwrapOk<ResponseOkCV>(readOnlyCall("can-execute-operation", [operationId]))
      .value as BooleanCV;
    expect(canExecuteAfter).toBeBool(true);

    const statusAfter = unwrapOk<ResponseOkCV>(readOnlyCall("get-operation-status", [operationId]));
    const statusAfterFields = (statusAfter.value as TupleCV).value;
    expect(statusAfterFields["approvals-count"]).toBeUint(2n);
    expect(statusAfterFields["required-approvals"]).toBeUint(2n);

    const executeResult = contractCall("execute-approved-operation", [operationId], owner);
    expect(executeResult.result.type).toBe("ok");

    const executedStatus = unwrapOk<ResponseOkCV>(readOnlyCall("get-operation-status", [operationId]));
    const executedStatusFields = (executedStatus.value as TupleCV).value;
    expect(executedStatusFields.executed).toBeBool(true);
    expect(executedStatusFields.expired).toBeBool(false);

    const pausedState = unwrapOk<ResponseOkCV>(readOnlyCall("is-paused")).value as BooleanCV;
    expect(pausedState).toBeBool(true);

    const secondExecute = contractCall("execute-approved-operation", [operationId], owner);
    expect(secondExecute.result).toBeErr(Cl.uint(412));

    contractCall("unpause", [], owner);
  });
});
