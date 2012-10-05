function try_back(errback){
  var bs = false;
  $(window).bind("unload",function(){bs=true});
  $(window).bind("beforeunload",function(){bs=true});
  history.back();
  switch(typeof errback){
    case "function": setTimeout(function(){if(!bs) errback()},100);break;
    case "string"  : setTimeout(function(){if(!bs) location.href=errback},100);break;
  }
  return bs;
}
$(function(){
  $('.back-or-top').click(function(){
    return try_back('/');
  });
});
