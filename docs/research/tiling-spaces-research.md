# Pesquisa: tiling, containers empilhados e Spaces no macOS

Data: 2026-08-30

Âmbito: pesquisa externa para a próxima decisão de produto e arquitetura do Lineup.

## Sumário executivo

- O modelo atual do Lineup já é o ponto certo para o produto: uma árvore recursiva de zonas por ecrã, com eixos e divisores editáveis. A pesquisa recomenda manter este modelo e não o trocar por um gestor de janelas dinâmico. Ver [ZoneTree.swift](../../Sources/ZonesCore/ZoneTree.swift) e [LayoutEdit.swift](../../Sources/ZonesCore/LayoutEdit.swift).

- A API pública de Accessibility da Apple é suficiente para descobrir, observar, redimensionar e reposicionar janelas. O acesso deve ser tratado como uma fronteira com permissões, timeouts e erros explícitos, não como uma operação sempre síncrona. Ver [`AXIsProcessTrustedWithOptions`](https://developer.apple.com/documentation/applicationservices/1459186-axisprocesstrustedwithoptions), [`AXUIElementSetAttributeValue`](https://developer.apple.com/documentation/applicationservices/1460434-axuielementsetattributevalue?changes=_3) e [`AXUIElement.h`](https://developer.apple.com/documentation/applicationservices/axuielement_h?changes=latest_ma_2).

- Spaces nativos não têm uma API pública documentada para criar, apagar, reordenar, trocar ou mover janelas. O AeroSpace documenta esta limitação e implementa workspaces virtuais próprios; o Lineup deve evitar essa emulação e apresentar zonas e layouts, não Spaces. Ver [emulation of virtual workspaces](https://nikitabobko.github.io/AeroSpace/guide#emulation-of-virtual-workspaces) e [`NSWindow.CollectionBehavior`](https://developer.apple.com/documentation/appkit/nswindow/collectionbehavior-swift.struct).

- O Lineup pode reutilizar ideias de árvore, normalização, containers tabbed/stacked e previews. Deve evitar código específico de compositores Wayland, APIs privadas, a scripting addition do yabai e código GPL do Loop.

## Matriz comparativa

| Projeto | Modelo | Integração macOS | Licença | Aplicação ao Lineup |
| --- | --- | --- | --- | --- |
| [Hyprland](https://github.com/hyprwm/Hyprland) | Compositor Wayland para Linux; tem workspaces, layouts Dwindle/Master e grupos tabbed ([dispatchers](https://wiki.hypr.land/configuring/core/dispatchers/), [Dwindle](https://wiki.hypr.land/0.55.0/Configuring/Layouts/Dwindle-Layout/), [Master](https://wiki.hypr.land/Configuring/Layouts/Master-Layout/)). | Não é código portátil para AppKit/Accessibility. | [BSD-3-Clause](https://github.com/hyprwm/Hyprland/blob/main/LICENSE) | Usar conceitos de árvore, foco e grupos. Evitar o compositor, Wayland IPC, workspaces dinâmicos e configuração Lua. |
| [AeroSpace](https://github.com/nikitabobko/AeroSpace) | Árvore i3-like; containers `tiles` e `accordion`, orientação horizontal/vertical e nesting arbitrário ([tree](https://nikitabobko.github.io/AeroSpace/guide#tree), [layouts](https://nikitabobko.github.io/AeroSpace/guide#layouts)). | Usa workspaces virtuais próprios por causa das limitações de Spaces; o README documenta uma exceção de API privada para obter o ID da janela ([README](https://github.com/nikitabobko/AeroSpace)). | [MIT](https://github.com/nikitabobko/AeroSpace/blob/main/LICENSE.txt) | Melhor referência para árvore e trade-offs de Spaces. Não copiar a emulação de janelas escondidas nem a API privada. |
| [yabai](https://github.com/asmvik/yabai) | BSP, `stack` e `float` por Space; CLI para foco, troca, warp e regras ([manual](https://github.com/asmvik/yabai/blob/master/doc/yabai.asciidoc)). | A scripting addition opcional do Dock exige desativar parcialmente o SIP e habilita operações de Spaces ([SIP](https://github.com/asmvik/yabai/wiki/Disabling-System-Integrity-Protection)). | [MIT](https://github.com/asmvik/yabai/blob/master/LICENSE.txt) | Usar como referência de operações e diagnósticos. Evitar SIP, scripting addition e controle de Spaces. |
| [Amethyst](https://github.com/ianyh/Amethyst) | Tiling automático, com Tall, Wide, Two Pane, Column, Row, Fullscreen e BSP; layouts customizados recebem janelas e devolvem frames ([layouts](https://github.com/ianyh/Amethyst#available-layouts), [custom layouts](https://github.com/ianyh/Amethyst/blob/development/docs/custom-layouts.md)). | Accessibility permission; comportamento ligado a Spaces pode trocar a ordem de Spaces ([README](https://github.com/ianyh/Amethyst)). | [MIT](https://github.com/ianyh/Amethyst/blob/development/LICENSE.md) | Reutilizar a separação entre cálculo de frames e mutação AX. Não adoptar a política de tiling automático. |
| [Rectangle](https://github.com/rxhanson/Rectangle) | Ações discretas de snap, metades, cantos, terços e preview de footprint ([README](https://github.com/rxhanson/Rectangle)). | Accessibility; o código tem fallback de elementos, timeout AX e exclusões de processos ([AccessibilityElement.swift](https://github.com/rxhanson/Rectangle/blob/main/Rectangle/AccessibilityElement.swift)). | [MIT](https://github.com/rxhanson/Rectangle/blob/main/LICENSE) | Referência forte para preview, erros e ações previsíveis. Não resolve a edição recursiva de zonas. |
| [Loop](https://github.com/MrKai77/Loop) | Menu radial acionado por tecla e movimento do cursor, preview antes do commit e stash de janelas ([README](https://github.com/MrKai77/Loop)). | App macOS com Accessibility. | [GPL-3.0](https://github.com/MrKai77/Loop/blob/develop/LICENSE) | Usar apenas ideias de interação. Não copiar código GPL para um produto com outra licença. |
| [AXSwift](https://github.com/tmandry/AXSwift) | Wrapper Swift fino e tipado sobre a API C de Accessibility, com erros explícitos e cobertura da API ([README](https://github.com/tmandry/AXSwift)). | Usa a API pública AX. | [MIT](https://github.com/tmandry/AXSwift/blob/master/LICENSE) | Avaliar apenas se a camada AX local ficar insuficiente; o Lineup já tem uma fronteira local pequena. |
| [Swindler](https://github.com/tmandry/Swindler) | Modelo de janelas em memória e eventos externos separados das operações próprias; documenta que IPC AX pode bloquear por segundos ([README](https://github.com/tmandry/Swindler)). | Swift/Accessibility; o projeto está em desenvolvimento. | [MIT](https://github.com/tmandry/Swindler/blob/master/LICENSE) | Boa referência de estado e tolerância a IPC. Não adicionar sem verificar manutenção e compatibilidade atual. |

## O que é reutilizável do Hyprland

Os conceitos são úteis, mas a implementação não é transferível: o Hyprland é um compositor Wayland/Linux, enquanto o Lineup controla aplicações existentes através de AppKit e Accessibility ([README do Hyprland](https://github.com/hyprwm/Hyprland)).

- As [workspace rules](https://wiki.hypr.land/configuring/core/rules/workspace-rules/) associam um workspace a monitor, layout, gaps, bordas e persistência. Para o Lineup, a tradução segura é manter um layout por ecrã e guardar as escolhas no documento do utilizador. Não é necessário criar workspaces.

- Os [dispatchers](https://wiki.hypr.land/configuring/core/dispatchers/) separam intenção de ação: foco, mover, trocar, renomear e alternar grupos. Esta separação é útil para comandos internos do Lineup, por exemplo `split`, `merge`, `move-window-to-zone` e `focus-zone`, sem expor um protocolo de compositor.

- Os [grupos](https://wiki.hypr.land/configuring/core/dispatchers/#group) funcionam como um container tabbed, ocupam uma área de janela e têm operações `next`, `prev`, `active`, `lock` e `move_window`. Isto é uma boa semântica futura para um container visual do Lineup, mas não é requisito para a versão atual.

- O [Dwindle](https://wiki.hypr.land/0.55.0/Configuring/Layouts/Dwindle-Layout/) usa uma árvore binária BSP e pode preservar a direção de split. O [Master](https://wiki.hypr.land/Configuring/Layouts/Master-Layout/) mantém um ou mais masters de um lado e uma stack do outro. São padrões para estudar, não defaults: as zonas do Lineup são desenhadas pelo utilizador e devem conservar a geometria escolhida.

## macOS: APIs públicas e limites

### Accessibility e janela

- A aplicação deve verificar confiança com [`AXIsProcessTrustedWithOptions`](https://developer.apple.com/documentation/applicationservices/1459186-axisprocesstrustedwithoptions). O prompt é assíncrono, portanto a UI deve explicar como ativar a permissão e permitir tentar novamente.

- [`AXUIElementCreateApplication`](https://developer.apple.com/documentation/applicationservices/1459374-axuielementcreateapplication?language=objc) cria o elemento de uma aplicação a partir do PID. [`AXUIElementSetAttributeValue`](https://developer.apple.com/documentation/applicationservices/1460434-axuielementsetattributevalue?changes=_3) pode escrever posição e tamanho, mas devolve erros para elementos inválidos, atributos não suportados e aplicações que não respondem.

- [`kAXPositionAttribute`](https://developer.apple.com/documentation/applicationservices/kaxpositionattribute) usa coordenadas globais com origem no canto superior esquerdo. [`kAXSizeAttribute`](https://developer.apple.com/documentation/applicationservices/kaxsizeattribute?changes=latest_ma_2&language=objc) fornece o tamanho. Os valores CGPoint, CGSize e CGRect devem ser encapsulados como [`AXValue`](https://developer.apple.com/documentation/applicationservices/axattributeconstants_h?language=objc) e lidos com [`AXValueGetValue`](https://developer.apple.com/documentation/applicationservices/1462933-axvaluegetvalue).

- [`AXUIElementCopyElementAtPosition`](https://developer.apple.com/documentation/applicationservices/1462077-axuielementcopyelementatposition?changes=_6&language=objc) permite hit testing. Isto pode apoiar a escolha de uma janela sob o cursor, mas não substitui o estado próprio do editor.

- [`AXObserverCreate`](https://developer.apple.com/documentation/applicationservices/1460133-axobservercreate?changes=_6) e [`AXObserverAddNotification`](https://developer.apple.com/documentation/applicationservices/1462089-axobserveraddnotification?changes=__9&language=objc) permitem observar uma aplicação. A documentação de [notificações AX](https://developer.apple.com/documentation/applicationservices/axnotificationconstants_h?changes=lat_3_1_4_6) indica um observer por aplicação; o Lineup deve coalescer eventos e manter fallback de leitura, porque uma aplicação pode não emitir todos os eventos esperados.

- [`CGWindowListCopyWindowInfo`](https://developer.apple.com/documentation/coregraphics/cgwindowlistcopywindowinfo%28_%3A_%3A%29?changes=_1_6&language=objc) é adequado para descobrir janelas e bounds do Window Server. É uma fonte de informação, não um substituto para `AXUIElementSetAttributeValue` quando é necessário mover ou redimensionar.

### Ecrãs, menu bar e Spaces

- [`NSScreen.screens`](https://developer.apple.com/documentation/appkit/nsscreen/screens) pode mudar quando um display é ligado, desligado ou reconfigurado e não deve ser tratado como cache permanente. [`NSScreen.frame`](https://developer.apple.com/documentation/appkit/nsscreen/frame) inclui a área completa; [`visibleFrame`](https://developer.apple.com/documentation/appkit/nsscreen/visibleframe) exclui menu bar e Dock. O cálculo de zonas deve escolher explicitamente uma destas áreas e recalcular após mudanças.

- [`NSScreen.screensHaveSeparateSpaces`](https://developer.apple.com/documentation/appkit/nsscreen/screenshaveseparatespaces) apenas informa a preferência de Spaces separados por ecrã. [`NSWindow.CollectionBehavior`](https://developer.apple.com/documentation/appkit/nswindow/collectionbehavior-swift.struct) controla como uma janela da própria aplicação participa em Spaces, mas não fornece uma API de ciclo de vida para criar, apagar, reordenar ou mover Spaces.

- A documentação do [AeroSpace sobre workspaces virtuais](https://nikitabobko.github.io/AeroSpace/guide#emulation-of-virtual-workspaces) enumera limitações práticas dos Spaces nativos: animações lentas, limite documentado de 16 Spaces por monitor e ausência de hotkeys/API pública para criar, apagar, reordenar e mover janelas entre Spaces. O AeroSpace esconde janelas de workspaces inativos numa área do ecrã, com efeitos colaterais de foco, Mission Control e monitores. O Lineup não deve repetir esta técnica.

- O [AeroSpace também documenta](https://nikitabobko.github.io/AeroSpace/guide#dialog-heuristics) que algumas aplicações implementam diálogos Accessibility de forma incorreta. Classificação por role e app deve ser defensiva, e uma janela que não possa ser movida deve produzir um estado visível de falha, não uma falsa confirmação.

### Consequências de implementação

- Manter uma camada AX pequena e central. Fazer preflight de confiança, usar timeout, distinguir `cannotComplete`, atributo não suportado e elemento desaparecido, e confirmar o frame depois da escrita.

- Usar observers por PID, debounce de notificações e uma leitura de reconciliação. O [Rectangle usa `AXUIElementSetMessagingTimeout`](https://github.com/rxhanson/Rectangle/blob/main/Rectangle/AccessibilityElement.swift) e fallbacks de descoberta; é um padrão prático para estudar.

- Recalcular ecrãs e `visibleFrame` em cada mudança de configuração. Não assumir que o monitor principal, escala Retina ou origem global continuam iguais.

- Não usar APIs privadas de WindowServer nem exigir SIP parcialmente desativado. No yabai, essas opções são explícitas na [documentação de SIP](https://github.com/asmvik/yabai/wiki/Disabling-System-Integrity-Protection) e aumentam o custo de segurança, suporte e instalação.

## Modelo de layout e containers

### Estado atual e proposta

O `Node` atual do Lineup é `leaf` ou `split(axis, dividers, children)`; `LayoutEdit` já divide folhas, faz merge e limita divisores ([ZoneTree.swift](../../Sources/ZonesCore/ZoneTree.swift), [LayoutEdit.swift](../../Sources/ZonesCore/LayoutEdit.swift)).

**Proposta, inferência a partir das fontes:**

1. Manter `Node` como árvore imutável de zonas. Cada split conserva eixo e posições de divisores definidos pelo utilizador. A passagem de geometria recebe um rect de ecrã, aplica gaps e recursa pelos filhos.

2. Preservar o eixo explícito. O Dwindle pode escolher o eixo pela proporção da área, mas essa mutação é útil para tiling automático e pode surpreender num layout desenhado à mão. A ordem das folhas e os divisores devem ser estáveis após abrir, fechar ou editar uma zona.

3. Normalizar apenas estados estruturais seguros: remover um split com um filho, rejeitar ou ajustar divisores fora do intervalo e manter uma ordem determinística. O princípio é semelhante à normalização documentada pelo [AeroSpace](https://nikitabobko.github.io/AeroSpace/guide#tree), sem importar a sua política de workspaces.

4. Separar cálculo de frames da mutação de janelas. O padrão é explícito nos [custom layouts do Amethyst](https://github.com/ianyh/Amethyst/blob/development/docs/custom-layouts.md), onde uma função recebe janelas e screen frame e devolve assignments. Para o Lineup, a mutação continua na fronteira AX local.

5. Se houver necessidade real de stack/tab no futuro, adicionar um modo do container com `selectedChild` e rect do pai. A semântica [stacking/tabbed do i3](https://i3wm.org/docs/userguide.html#_stacking_tabbed_layout) mostra que todos os filhos partilham a área e só o foco fica visível. No macOS, esta funcionalidade deve ser modelada no próprio Lineup; esconder janelas numa área fora do ecrã para simular um workspace é frágil.

### O que não adicionar nesta fase

- Não atribuir automaticamente cada janela aberta à próxima folha. O produto tem zonas escolhidas pelo utilizador, e a ação principal é escolher um destino.

- Não adoptar uma política master/stack ou BSP dinâmica como default. Estas políticas são boas para gestores de janelas, mas removem controlo visual do editor do Lineup.

- Não executar layouts JavaScript arbitrários, apesar de o Amethyst os suportar. Isso aumenta superfície de segurança, persistência e suporte sem resolver o caso de uso atual.

## Implicações de produto e UX

- Usar “layout”, “zona” e “ecrã”. Evitar “workspace” e “Space” na UI, para não prometer troca de ambientes que o Lineup não controla. A descrição de produto e o objetivo atual já posicionam o Lineup como layouts por ecrã ([GOAL.md](../../GOAL.md), [PRODUCT.md](../../PRODUCT.md)).

- Manter o editor visual recursivo: escolher um ecrã, dividir uma folha, arrastar um divisor e fazer merge. Mostrar preview da área antes de confirmar, inspirado no [footprint preview do Rectangle](https://github.com/rxhanson/Rectangle) e no preview radial do [Loop](https://github.com/MrKai77/Loop), mas implementar a interação do Lineup de forma independente.

- A permissão Accessibility deve ter estado claro no menu bar: pronto, permissão necessária, janela não suportada ou operação em curso. Não esconder o erro atrás de um snap que parece concluído.

- Para janelas não redimensionáveis, diálogos e apps com AX incompleto, oferecer mensagem curta e manter o layout intacto. O comportamento defensivo do [AeroSpace para diálogos](https://nikitabobko.github.io/AeroSpace/guide#dialog-heuristics) é uma referência.

- Manter rótulos de Accessibility nos controlos próprios. A Apple documenta que elementos customizados precisam de role, label, parent e frame acessíveis ([guia de elementos customizados](https://developer.apple.com/library/archive/documentation/Accessibility/Conceptual/AccessibilityMacOSX/ImplementingAccessibilityforCustomControls.html)).

- Não acrescentar atalhos globais ou workspaces por defeito só para imitar outro gestor. O [GOAL.md](../../GOAL.md) limita o produto às capacidades atuais de zonas, shift-drag, cycling e recorder.

## Riscos e mitigação

| Risco | Impacto | Mitigação recomendada |
| --- | --- | --- |
| Permissão AX ausente, revogada ou prompt ainda pendente | Nenhuma janela se move; confiança perdida | Preflight com [`AXIsProcessTrustedWithOptions`](https://developer.apple.com/documentation/applicationservices/1459186-axisprocesstrustedwithoptions), estado persistente e instruções curtas. |
| IPC AX lento, app bloqueada ou elemento destruído | UI bloqueada, frame parcial ou crash | Timeout, operação assíncrona, confirmação de frame, retry limitado e rollback lógico; [Swindler](https://github.com/tmandry/Swindler) documenta o custo de IPC. |
| App não implementa role/atributos de forma correta | Diálogo ou janela errada é movido | Heurísticas conservadoras, exclusões conhecidas e opção de cancelar; ver [AeroSpace dialog heuristics](https://nikitabobko.github.io/AeroSpace/guide#dialog-heuristics). |
| Display, escala, origem ou menu bar muda | Zonas desalinhadas ou fora do ecrã | Recalcular `NSScreen.screens`, frame/visibleFrame e transformações em cada mudança; ver [NSScreen.screens](https://developer.apple.com/documentation/appkit/nsscreen/screens). |
| Tamanho mínimo e janela não redimensionável | Sobreposição, perda de conteúdo ou falha silenciosa | Clamp de rect, validar `AXSize`, deixar a zona intacta quando a operação não é possível e explicar o motivo. |
| Full Screen, Stage Manager, Separate Spaces ou Mission Control | Estado visual divergente do modelo do Lineup | Tratar como cenários de teste; não prometer lifecycle ou sincronização de Spaces. |
| API privada, SIP ou emulação por janela escondida | Instalação frágil, risco de segurança e regressões do macOS | Usar apenas API pública; não seguir a implementação de [yabai com scripting addition](https://github.com/asmvik/yabai/wiki/Disabling-System-Integrity-Protection) nem a emulação do [AeroSpace](https://nikitabobko.github.io/AeroSpace/guide#emulation-of-virtual-workspaces). |
| Mistura de código com licenças incompatíveis | Obrigação de distribuir código ou avisos não planeados | Reimplementar ideias; se copiar código, preservar licença. Em particular, não copiar código do [Loop GPL-3.0](https://github.com/MrKai77/Loop/blob/develop/LICENSE). |

## Recomendação final

**Adoptar agora:**

- árvore recursiva atual, divisores explícitos e cálculo puro de geometria;
- fronteira AX pública com confiança, timeout, observers, reconciliação e erros visíveis;
- `NSScreen.visibleFrame` ou `frame` escolhido de forma explícita, com recálculo em mudanças de display;
- preview de snap e footprint, ações discretas e editor direto inspirados por Rectangle;
- normalização estrutural segura e separação entre layout e aplicação, inspiradas por AeroSpace e Amethyst.

**Evitar agora:**

- lifecycle de Spaces nativos e qualquer promessa de workspace virtual;
- APIs privadas, scripting addition do Dock e SIP parcialmente desativado;
- auto-tiling master/BSP que reescreva layouts desenhados pelo utilizador;
- código GPL do Loop ou execução de layouts JavaScript arbitrários;
- dependências AX externas antes de demonstrar que a camada local não cobre o caso.

**Decisão de produto:** o Lineup deve continuar a ser um editor nativo de zonas por ecrã, com colocação previsível de janelas. Containers stacked/tabbed podem ser uma extensão visual futura, dentro da árvore e sem alterar Spaces. A pesquisa não justifica adicioná-los à versão atual.

## Validação e próximos testes

- Testar TextEdit, Finder, Terminal, Chrome/Electron, diálogos e janelas não redimensionáveis; cobrir sucesso, timeout, atributo não suportado e elemento desaparecido.

- Testar ligar/desligar display, Retina, origens negativas, menu bar, Dock e mudanças de `visibleFrame`.

- Testar Full Screen, Stage Manager, Separate Spaces ligado/desligado e Mission Control como cenários de regressão, sem os transformar em dependências.

- Testar observers duplicados, debounce, aplicação fechada durante a operação, cancelamento e recuperação depois de erro.

- Testar layouts recursivos com vários níveis, divisores no limite, merge, undo/cancel e estabilidade dos rects depois de reabrir o editor.

## Decisão de produto depois da pesquisa

O pedido atual substitui os non-goals da fase anterior. A pesquisa continua a excluir Spaces
nativos, APIs privadas de Spaces, SIP alterado e staging off-screen, mas não exclui a nova tool.

A decisão acordada está em [tiles-implementation-plan.md](../tiles-implementation-plan.md):

- nome `Tiles`;
- geometria sempre derivada dos layouts de Zones;
- quatro workspaces globais do Lineup, sem controlo de Mission Control;
- cada folha como tile com stack ordenada e cycling por raise/focus;
- minimização pública apenas para janelas de workspaces inativos;
- recovery journal conservador antes de qualquer staging;
- configuração limitada a três atalhos opcionais e ao switch global do tool.

Esta decisão usa a separação de árvore/efeitos do AeroSpace e Amethyst, mas mantém a experiência e
os limites de segurança do Lineup. O gate de dez janelas, dois ecrãs e menos de dois segundos decide
se o staging por minimize é aceitável antes de começar o polish final.
