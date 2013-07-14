Backbone.RailsStore
===================

Backbone extensions to provide complete Rails interaction on CoffeeScript/Javascript, providing a remote search mechanism, keeping single reference models in memory, reporting refresh conflicts and consistently persisting models and there relations.



A idéia do Backbone.RailsStore veio quando era necessário salvar vários models de uma vez só, em uma operação que só poderia ser "salvar tudo ou nada". Além disso, percebeu-se que o Backbone.Relational, que era a maneira mais utilizada de fazer relacionamentos entre models, tinha problemas sérios quando havia relacionamentos de models mais elaborados, principalmente no envio dos dados para o servidor.

O Backbone.RailsStore tem um objeto Singleton, a *Store*, único no sistema. Este objeto tem uma referência para todos os Models na memória do navegador e na hora de salvar, detecta as mudanças em todos os models e as envia para o servidor. Este objeto tem também um método *findRemote()*, que faz uma busca no servidor, de um determinado tipo de model, similar ao *find()* no model Rails.

Para obter a Store:

<pre><code class="javascript">
store = Backbone.RailsStore.getInstance();
</code></pre>

Para buscar objetos no servidor (findRemote):

<pre><code class="javascript">
store.findRemote({
   ModelType: SglWeb.Models.Product,
   searchParams: {
      domain_id: SglWeb.currentDomain.get('id'),
      keyword: query
      }
   limit: 5,
   success: function() {/* codigo a ser executado no success */ },
   error: function() {/* código a ser executado no erro*/ }
});
</code></pre>

Para gravar no servidor:

<pre><code class="javascript">
store.save({
   success: function() {/* código a ser executado no success */},
   error: function() {/* código a ser executado no error */ }
})
</code></pre>

e

<pre><code class="javascript">
store.commit({
   success: function() {/* código a ser executado no success */},
   error: function() {/* código a ser executado no error */ }
})
</code></pre>

A diferença entre o save() e o commit() é que o commit envia também as informações dos models apagados.

Tem um método também para limpar todos os models da memória (*releaseAll()*). 

A idéia do RailsStore é criar uma espécie de 'contexto' dentro de uma tela, por exemplo, pensando em uma linha temporal, o usuário entra em uma tela, faz alterações em informações presentes em vários models, e depois salva. Ao salvar são enviadas todas as informações de novos models (para serem criados) e models modificados (para serem alterados) . Depois ao entrar em outro contexto, com carga de novos models, etc, pode ser chamado o método releaseAll() para fazer uma "limpeza" dos models do contexto anterior:

<pre><code class="javascript">
Backbone.RailsStore.getInstance().releaseAll();
</code></pre>
