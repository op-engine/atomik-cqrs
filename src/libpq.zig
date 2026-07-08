// C bindings for libpq (PostgreSQL C API)
// Generated for Phase 2: Database Operations
// Used to call PostgreSQL from Zig with real database operations

const c = @cImport({
    @cInclude("libpq-fe.h");
});

pub const PGconn = c.PGconn;
pub const PGresult = c.PGresult;

pub const ConnStatusType = c.ConnStatusType;
pub const ExecStatusType = c.ExecStatusType;

// Connection status values
pub const CONNECTION_OK = c.CONNECTION_OK;
pub const CONNECTION_BAD = c.CONNECTION_BAD;

// Execution status values
pub const PGRES_EMPTY_QUERY = c.PGRES_EMPTY_QUERY;
pub const PGRES_COMMAND_OK = c.PGRES_COMMAND_OK;
pub const PGRES_TUPLES_OK = c.PGRES_TUPLES_OK;
pub const PGRES_COPY_OUT = c.PGRES_COPY_OUT;
pub const PGRES_COPY_IN = c.PGRES_COPY_IN;
pub const PGRES_BAD_RESPONSE = c.PGRES_BAD_RESPONSE;
pub const PGRES_NONFATAL_ERROR = c.PGRES_NONFATAL_ERROR;
pub const PGRES_FATAL_ERROR = c.PGRES_FATAL_ERROR;

// Use C functions directly from libpq
pub const PQconnectdb = c.PQconnectdb;
pub const PQconnectdbParams = c.PQconnectdbParams;
pub const PQfinish = c.PQfinish;
pub const PQstatus = c.PQstatus;
pub const PQerrorMessage = c.PQerrorMessage;
pub const PQexecParams = c.PQexecParams;
pub const PQexec = c.PQexec;
pub const PQresultStatus = c.PQresultStatus;
pub const PQresultErrorMessage = c.PQresultErrorMessage;
pub const PQclear = c.PQclear;
pub const PQntuples = c.PQntuples;
pub const PQnfields = c.PQnfields;
pub const PQfname = c.PQfname;
pub const PQgetvalue = c.PQgetvalue;
pub const PQgetisnull = c.PQgetisnull;
pub const PQcmdTuples = c.PQcmdTuples;
pub const PQescapeString = c.PQescapeString;
pub const PQescapeBytea = c.PQescapeBytea;
pub const PQfreemem = c.PQfreemem;
