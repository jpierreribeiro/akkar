# Instalação controlada no Linux

Execute `bash bin/bootstrap-runtime /caminho/absoluto/novo-prefixo`. O destino
não pode existir; nada substitui o Lua do sistema ou os rocks do usuário.
Requer compilador C/make, git, curl, LuaRocks, headers OpenSSL, m4 e unzip.

Use `novo-prefixo/bin/runtime-exec akkar doctor --no-probe` e o mesmo launcher
para `akkar run app.lua`. Os caminhos Lua globais são excluídos. O manifesto
`runtime/substrate.env` fixa Lua/cqueues; `runtime/rocks.lock` fixa versões e
SHA-256 dos arquivos-fonte dos rocks. O CI usa o mesmo pin do cqueues.

Lua 5.4.6 preserva o baseline medido desta rodada; não é apresentado como a
versão corrigida mais recente. Atualizá-lo exige nova revisão de segurança e
compatibilidade. OpenSSL vem do host: sua identidade é registrada na instalação
e o doctor reprova divergência posterior. Compilador, libc e LuaRocks continuam
sendo ferramentas externas, portanto isto não é build hermético nem binário
estático portátil ou idêntico byte a byte.

O driver nativo opcional `akkar-pq` não é instalado; pgmoon continua padrão.
O aviso do LuaRocks sobre cqueues não registrado como rock é esperado para a
compilação manual: o bootstrap verifica o commit realmente carregado.
A instalação LuaRocks comum permanece separada. O job `controlled-install`
valida o prefixo fora do checkout; a preparação de release inclui os manifests,
sem publicar nada automaticamente. Detalhes em [inglês](../CONTROLLED-INSTALL.md).
