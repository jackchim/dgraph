import 'package:grpc/grpc.dart';
import 'package:protobuf/protobuf.dart';
import 'dgraph.dart';
import 'protos/api/api_pb.dart' as api;
import 'y/y.dart';
import 'dart:async';

// Txn is a single atomic transaction.
//
// A transaction lifecycle is as follows:
//
// 1. Created using NewTxn.
//
// 2. Various Query and Mutate calls made.
//
// 3. Commit or Discard used. If any mutations have been made, It's important
// that at least one of these methods is called to clean up resources. Discard
// is a no-op if Commit has already been called, so it's safe to defer a call
// to Discard immediately after NewTxn.
class Txn {
  api.TxnContext context;

	bool finished = false;
	bool mutated = false;
	bool readOnly = false;

	Dgraph dg;
	api.DgraphApi dc;

  static const ErrFinished = "Transaction has already been committed or discarded";
  static const ErrReadOnly = "Readonly transaction cannot run mutations or be committed";

  Txn({this.dg, this.dc, this.context});

  // Query sends a query to one of the connected dgraph instances. If no
  // mutations need to be made in the same transaction, it's convenient to chain
  // the method, e.g. NewTxn().Query(ctx, "...").
  Future<api.Response> Query(ClientContext ctx, String q) async {
    return await QueryWithVars(ctx, q, null);
  }

  // QueryWithVars is like Query, but allows a variable map to be used. This can
  // provide safety against injection attacks.
  Future<api.Response> QueryWithVars(ClientContext ctx, String q,
    Map<String,String> vars) async {
    if (finished) {
      throw ErrFinished;
    }
    api.Request req = api.Request();
    req.query = q;
    if (vars != null) {
      req.vars.addAll(vars);
    }
    req.startTs = context.startTs;
    req.readOnly = readOnly;
    api.Response resp;
    resp = await dc.query(ctx, req);
    mergeContext(resp.txn);
    return resp;
  }

  void mergeContext(api.TxnContext src) {
    if (src != null) {
      if (context.startTs == 0) {
        context.startTs = src.startTs;
      }
      if (context.startTs != src.startTs) {
        throw Exception("StartTs mismatch");
      }
      context.keys.addAll(src.keys);
      context.preds.addAll(src.preds);
    }
  }

  // Mutate allows data stored on dgraph instances to be modified. The fields in
  // api.Mutation come in pairs, set and delete. Mutations can either be
  // encoded as JSON or as RDFs.
  //
  // If CommitNow is set, then this call will result in the transaction
  // being committed. In this case, an explicit call to Commit doesn't need to
  // subsequently be made.
  //
  // If the mutation fails, then the transaction is discarded and all future
  // operations on it will fail.
  Future<api.Assigned> Mutate(ClientContext ctx, api.Mutation mu) async {
    if (readOnly) {
      throw ErrReadOnly;
    }
    if (finished) {
      throw ErrFinished;
    }
    mutated = true;
    mu.startTs = context.startTs;
    api.Assigned ag;
    try {
      ag = await dc.mutate(ctx, mu);
      if (mu.commitNow) {
        finished = true;
      }
      mergeContext(ag.context);
    } on GrpcError catch(e) {
      // Since a mutation error occurred, the txn should no longer be used
      // (some mutations could have applied but not others, but we don't know
      // which ones).  Discarding the transaction enforces that the user
      // cannot use the txn further.
      try {
        Discard(ctx);
      } catch (e) {
        // Ignore error - user should see the original error.
      }
      // Transaction could be aborted(codes.Aborted) if CommitNow was true, or server could send a
      // message that this mutation conflicts(codes.FailedPrecondition) with another transaction.
      int s = e.code;
      if ((s == StatusCode.aborted) || (s == StatusCode.failedPrecondition)) {
        throw ErrAborted;
      }
    } finally {
      return ag;
    }
  }

  // Commit commits any mutations that have been made in the transaction. Once
  // Commit has been called, the lifespan of the transaction is complete.
  //
  // Errors could be returned for various reasons. Notably, ErrAborted could be
  // returned if transactions that modify the same data are being run
  // concurrently. It's up to the user to decide if they wish to retry. In this
  // case, the user should create a new transaction.
  void Commit(ClientContext ctx) {
    if (readOnly) {
      throw ErrReadOnly;
    } else if (finished) {
      throw ErrFinished;
    } else {
      finished = true;
      if (mutated) {
        try {
          dc.commitOrAbort(ctx, context);
        } on GrpcError catch (e) {
          if (e.code == StatusCode.aborted) {
            throw ErrAborted;
          }
        }        
      } 
    }
  }

  // Discard cleans up the resources associated with an uncommitted transaction
  // that contains mutations. It is a no-op on transactions that have already
  // been committed or don't contain mutations. Therefore it is safe (and
  // recommended) to call as a deferred function immediately after a new
  // transaction is created.
  //
  // In some cases, the transaction can't be discarded, e.g. the grpc connection
  // is unavailable. In these cases, the server will eventually do the
  // transaction clean up.
  void Discard(ClientContext ctx) {
    if (!finished) {
      finished = true;
      if (mutated) {
        context.aborted = true;
        dc.commitOrAbort(ctx, context);
      }
    }
  }
}