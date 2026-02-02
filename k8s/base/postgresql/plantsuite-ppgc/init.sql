-- Conectar ao banco vernemq
\c vernemq;

-- Definir o schema vernemq como padrão para as operações subsequentes
SET search_path TO vernemq;

-- Criar extensão pgcrypto (se necessário no schema vernemq)
CREATE EXTENSION IF NOT EXISTS pgcrypto;

-- Criar tabela vmq_auth_acl no schema vernemq apenas se não existir
CREATE TABLE IF NOT EXISTS vmq_auth_acl (
   mountpoint character varying(36) NOT NULL,
   client_id character varying(128) NOT NULL,
   username character varying(128) NOT NULL,
   password character varying(128),
   publish_acl json,
   subscribe_acl json,
   CONSTRAINT vmq_auth_acl_primary_key PRIMARY KEY (mountpoint, client_id, username),
   CONSTRAINT vmq_auth_acl_unique_username_per_mountpoint UNIQUE (mountpoint, username)
);

-- Definir o owner da tabela para vernemq
ALTER TABLE vmq_auth_acl OWNER TO vernemq;