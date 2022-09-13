"use strict";(self.webpackChunkdocs=self.webpackChunkdocs||[]).push([[985],{3905:(e,t,r)=>{r.d(t,{Zo:()=>p,kt:()=>f});var n=r(7294);function o(e,t,r){return t in e?Object.defineProperty(e,t,{value:r,enumerable:!0,configurable:!0,writable:!0}):e[t]=r,e}function i(e,t){var r=Object.keys(e);if(Object.getOwnPropertySymbols){var n=Object.getOwnPropertySymbols(e);t&&(n=n.filter((function(t){return Object.getOwnPropertyDescriptor(e,t).enumerable}))),r.push.apply(r,n)}return r}function a(e){for(var t=1;t<arguments.length;t++){var r=null!=arguments[t]?arguments[t]:{};t%2?i(Object(r),!0).forEach((function(t){o(e,t,r[t])})):Object.getOwnPropertyDescriptors?Object.defineProperties(e,Object.getOwnPropertyDescriptors(r)):i(Object(r)).forEach((function(t){Object.defineProperty(e,t,Object.getOwnPropertyDescriptor(r,t))}))}return e}function c(e,t){if(null==e)return{};var r,n,o=function(e,t){if(null==e)return{};var r,n,o={},i=Object.keys(e);for(n=0;n<i.length;n++)r=i[n],t.indexOf(r)>=0||(o[r]=e[r]);return o}(e,t);if(Object.getOwnPropertySymbols){var i=Object.getOwnPropertySymbols(e);for(n=0;n<i.length;n++)r=i[n],t.indexOf(r)>=0||Object.prototype.propertyIsEnumerable.call(e,r)&&(o[r]=e[r])}return o}var l=n.createContext({}),s=function(e){var t=n.useContext(l),r=t;return e&&(r="function"==typeof e?e(t):a(a({},t),e)),r},p=function(e){var t=s(e.components);return n.createElement(l.Provider,{value:t},e.children)},u={inlineCode:"code",wrapper:function(e){var t=e.children;return n.createElement(n.Fragment,{},t)}},d=n.forwardRef((function(e,t){var r=e.components,o=e.mdxType,i=e.originalType,l=e.parentName,p=c(e,["components","mdxType","originalType","parentName"]),d=s(r),f=o,g=d["".concat(l,".").concat(f)]||d[f]||u[f]||i;return r?n.createElement(g,a(a({ref:t},p),{},{components:r})):n.createElement(g,a({ref:t},p))}));function f(e,t){var r=arguments,o=t&&t.mdxType;if("string"==typeof e||o){var i=r.length,a=new Array(i);a[0]=d;var c={};for(var l in t)hasOwnProperty.call(t,l)&&(c[l]=t[l]);c.originalType=e,c.mdxType="string"==typeof e?e:o,a[1]=c;for(var s=2;s<i;s++)a[s]=r[s];return n.createElement.apply(null,a)}return n.createElement.apply(null,r)}d.displayName="MDXCreateElement"},8142:(e,t,r)=>{r.r(t),r.d(t,{assets:()=>l,contentTitle:()=>a,default:()=>u,frontMatter:()=>i,metadata:()=>c,toc:()=>s});var n=r(7462),o=(r(7294),r(3905));const i={sidebar_position:2},a="Single-node cluster with Docker",c={unversionedId:"setup/with-docker",id:"setup/with-docker",title:"Single-node cluster with Docker",description:"First provision TigerBeetle's data directory.",source:"@site/pages/setup/with-docker.md",sourceDirName:"setup",slug:"/setup/with-docker",permalink:"/setup/with-docker",draft:!1,editUrl:"https://github.com/tigerbeetledb/docs/tree/main/pages/setup/with-docker.md",tags:[],version:"current",sidebarPosition:2,frontMatter:{sidebar_position:2},sidebar:"tutorialSidebar",previous:{title:"Getting started",permalink:"/"},next:{title:"Single-node cluster from source",permalink:"/setup/from-source"}},l={},s=[],p={toc:s};function u(e){let{components:t,...r}=e;return(0,o.kt)("wrapper",(0,n.Z)({},p,r,{components:t,mdxType:"MDXLayout"}),(0,o.kt)("h1",{id:"single-node-cluster-with-docker"},"Single-node cluster with Docker"),(0,o.kt)("p",null,"First provision TigerBeetle's data directory."),(0,o.kt)("pre",null,(0,o.kt)("code",{parentName:"pre",className:"language-bash"},'$ docker run -v $(pwd)/data:/data ghcr.io/coilhq/tigerbeetle \\\n    format --cluster=0 --replica=0 /data/0_0.tigerbeetle\ninfo(io): creating "0_0.tigerbeetle"...\ninfo(io): allocating 660.140625MiB...\n')),(0,o.kt)("p",null,"Then run the server."),(0,o.kt)("pre",null,(0,o.kt)("code",{parentName:"pre",className:"language-bash"},'$ docker run -p 3000:3000 -v $(pwd)/data:/data ghcr.io/coilhq/tigerbeetle \\\n    start --addresses=0.0.0.0:3000 /data/0_0.tigerbeetle\ninfo(io): opening "0_0.tigerbeetle"...\ninfo(main): 0: cluster=0: listening on 0.0.0.0:3000\n')),(0,o.kt)("p",null,"Now you can connect to the running server with any client. For a quick\nstart, try ",(0,o.kt)("a",{parentName:"p",href:"/usage/node-cli"},"creating accounts and transfers in the Node\nCLI"),"."))}u.isMDXComponent=!0}}]);