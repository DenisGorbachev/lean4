/*
Copyright (c) 2014 Microsoft Corporation. All rights reserved.
Released under Apache 2.0 license as described in the file LICENSE.

Author: Leonardo de Moura
*/
#pragma once
#include <string>
#include <utility>
#include <vector>
#include "util/scoped_map.h"
#include "util/script_state.h"
#include "util/name_map.h"
#include "util/exception.h"
#include "kernel/environment.h"
#include "kernel/expr_maps.h"
#include "library/io_state.h"
#include "frontends/lean/scanner.h"
#include "frontends/lean/cmd_table.h"
#include "frontends/lean/parser_pos_provider.h"

namespace lean {
struct parameter {
    pos_info    m_pos;
    name        m_name;
    expr        m_type;
    binder_info m_bi;
    parameter(pos_info const & p, name const & n, expr const & t, binder_info const & bi):
        m_pos(p), m_name(n), m_type(t), m_bi(bi) {}
    parameter():m_pos(0, 0) {}
};

/** \brief Exception used to track parsing erros, it does not leak outside of this class. */
struct parser_error : public exception {
    pos_info m_pos;
    parser_error(char const * msg, pos_info const & p):exception(msg), m_pos(p) {}
    parser_error(sstream const & msg, pos_info const & p):exception(msg), m_pos(p) {}
    virtual exception * clone() const { return new parser_error(m_msg.c_str(), m_pos); }
    virtual void rethrow() const { throw *this; }
};

class parser {
    typedef std::pair<expr, unsigned> local_entry;
    typedef scoped_map<name, local_entry, name_hash, name_eq> local_decls;

    environment             m_env;
    io_state                m_ios;
    script_state *          m_ss;
    bool                    m_verbose;
    bool                    m_use_exceptions;
    bool                    m_show_errors;

    scanner                 m_scanner;
    scanner::token_kind     m_curr;
    local_decls             m_local_decls;
    pos_info                m_last_cmd_pos;
    pos_info                m_last_script_pos;
    unsigned                m_next_tag_idx;
    bool                    m_found_errors;
    pos_info_table_ptr      m_pos_table;

    enum class scope_kind { Scope, Namespace, Structure };
    std::vector<name>       m_namespace_prefixes;
    std::vector<scope_kind> m_scope_kinds;

    void display_error_pos(unsigned line, unsigned pos);
    void display_error_pos(pos_info p);
    void display_error(char const * msg, unsigned line, unsigned pos);
    void display_error(char const * msg, pos_info p);
    void display_error(exception const & ex);
    void throw_parser_exception(char const * msg, pos_info p);
    void throw_nested_exception(exception & ex, pos_info p);

    void sync_command();
    void protected_call(std::function<void()> && f, std::function<void()> && sync);

    tag get_tag(expr e);

    void updt_options();
public:
    parser(environment const & env, io_state const & ios,
           std::istream & strm, char const * str_name,
           script_state * ss = nullptr, bool use_exceptions = false);

    environment const & env() const { return m_env; }
    io_state const & ios() const { return m_ios; }
    script_state * ss() const { return m_ss; }

    parameter parse_binder();
    void parse_binders(buffer<parameter> & r);

    expr parse_expr(unsigned rbp = 0);
    expr parse_scoped_expr(unsigned num_locals, expr const * locals, unsigned rbp = 0);

    tactic parse_tactic(unsigned rbp = 0);

    /** \brief Return the current position information */
    pos_info pos() const { return mk_pair(m_scanner.get_line(), m_scanner.get_pos()); }
    void save_pos(expr e, pos_info p);

    /** \brief Read the next token. */
    void scan() { m_curr = m_scanner.scan(m_env); }
    /** \brief Return the current token */
    scanner::token_kind curr() const { return m_curr; }
    /** \brief Read the next token if the current one is not End-of-file. */
    void next() { if (m_curr != scanner::token_kind::Eof) scan(); }

    mpq const & get_num_val() const { return m_scanner.get_num_val(); }
    name const & get_name_val() const { return m_scanner.get_name_val(); }
    std::string const & get_str_val() const { return m_scanner.get_str_val(); }
    token_info const & get_token_info() const { return m_scanner.get_token_info(); }
    std::string const & get_stream_name() const { return m_scanner.get_stream_name(); }

    /** parse all commands in the input stream */
    bool operator()();
};
}
