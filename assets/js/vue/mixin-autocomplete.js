(function() {
  /* Required in consumer:
  module.exports = {
    computed: {
      autocompleteOptions: function() { return [] }
    },
    methods: {
      autocompleted: function(option) { ... }
    }
  };
  */

  Convos.mixin.autocomplete = {
    computed: {
      labelActive: function() {
        return this.autocompleteValue || this.placeholder || this.hasFocus;
      }
    },
    data: function() {
      return {
        autocompleteValue: "",
        hasFocus: false,
        selected: -1,
        selectStart: 0
      };
    },
    methods: {
      keydown: function(e) {
        switch (e.keyCode) {
          case 38: // up
          case 40: // down
            e.preventDefault();
        }
      },
      keyup: function(e) {
        switch (e.keyCode) {
          case 13: // enter
            if (this.selected >= 0 && this.autocompleteOptions[this.selected]) {
              this.autocompleted(this.autocompleteOptions[this.selected]);
            }
            else if (this.autocompleteValue.length) {
              this.autocompleted({value: this.autocompleteValue});
            }
            break;
          case 38: // up
            if (--this.selected < this.selectStart) this.selected = this.autocompleteOptions.length - 1;
            this.scrollIntoView();
            break;
          case 40: // down
            if (++this.selected >= this.autocompleteOptions.length) this.selected = 0;
            this.scrollIntoView();
            break;
          default:
            if (!this.autocompleteValue) this.selected = this.selectStart;
        }
      },
      optionClass: function(i) {
        return {active: i == this.selected ? true : false, link: true};
      },
      scrollIntoView: function() {
        var i = this.selected < 0 ? 0 : this.selected;
        var li = this.$el.querySelectorAll("li")[this.selected];
        if (li) this.$el.querySelector(".autocomplete").scrollTop = li.offsetTop;
      }
    }
  };
})();
